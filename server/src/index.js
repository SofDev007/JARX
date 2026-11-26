// JARX server: Google sign-in, ban check, sync, and the owner's admin page.
// One Cloudflare Worker + one D1 database (../schema.sql). No dependencies.
//
// ponytail: no rate limiting; fine for ~60 users on the free plan. Add a
// per-IP limit (Cloudflare rate-limiting binding) if the Worker gets abused.

import { FAVICON_PNG_B64 } from './favicon.js';
import * as ai from './ai.js';

const GOOGLE_CERTS = 'https://www.googleapis.com/oauth2/v3/certs';
const SESSION_DAYS = 180;
// library, history and taste are one row per user; listening is one row per
// phone (listening:<device id>) so the phones' counts can be added up.
const KIND = /^(library|history|taste|listening:[0-9a-f]{8,32})$/;
const MAX_SNAPSHOT = 1_900_000; // D1 keeps at most 2 MB in one value
// Listening rows are small; a cap on their size and number per account stops
// one account from filling the database with made-up phone ids.
const MAX_LISTENING = 256_000;
const MAX_PHONES = 10;
const ADMIN_DEVICE = 'admin page';

const json = (body, status = 200) => Response.json(body, { status });
const now = () => Date.now();
const hex = (bytes) =>
  [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, '0')).join('');
const sha256Hex = async (text) =>
  hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)));
const b64url = (s) =>
  Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));
const clip = (v, n) => (v == null ? null : String(v).slice(0, n));

// ---- Google sign-in tokens ----

let certs = { keys: [], until: 0 };
async function googleKey(kid, retry = true) {
  if (certs.until < now()) {
    const res = await fetch(GOOGLE_CERTS);
    if (!res.ok) throw new Error('google certs ' + res.status);
    const age = /max-age=(\d+)/.exec(res.headers.get('cache-control') || '');
    certs = { keys: (await res.json()).keys, until: now() + (age ? +age[1] * 1000 : 3600_000) };
  }
  const key = certs.keys.find((k) => k.kid === kid);
  if (key || !retry) return key;
  certs.until = 0; // Google rotated its keys since we cached them
  return googleKey(kid, false);
}

/** The token's claims when it is a real, current Google sign-in for this app; else null. */
export async function verifyGoogleToken(token, clientId) {
  const parts = String(token || '').split('.');
  if (parts.length !== 3) return null;
  let header, claims;
  try {
    header = JSON.parse(new TextDecoder().decode(b64url(parts[0])));
    claims = JSON.parse(new TextDecoder().decode(b64url(parts[1])));
  } catch {
    return null;
  }
  if (header.alg !== 'RS256') return null;
  const jwk = await googleKey(header.kid);
  if (!jwk) return null;
  const key = await crypto.subtle.importKey(
    'jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
  const signed = new TextEncoder().encode(parts[0] + '.' + parts[1]);
  if (!(await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, b64url(parts[2]), signed))) return null;
  if (!['accounts.google.com', 'https://accounts.google.com'].includes(claims.iss)) return null;
  if (claims.aud !== clientId) return null;
  if (!(claims.exp > now() / 1000)) return null;
  if (claims.email_verified !== true && claims.email_verified !== 'true') return null;
  if (!claims.sub || !claims.email) return null;
  return claims;
}

// ---- Sessions ----

async function sessionUser(req, env) {
  const m = /^Bearer ([0-9a-f]{64})$/.exec(req.headers.get('authorization') || '');
  if (!m) return null;
  return env.DB.prepare(
    `SELECT u.*, s.token_hash FROM sessions s JOIN users u ON u.id = s.user_id
     WHERE s.token_hash = ? AND s.expires_at > ?`)
    .bind(await sha256Hex(m[1]), now()).first();
}

async function signIn(req, env) {
  const body = await req.json().catch(() => ({}));
  const g = await verifyGoogleToken(body.idToken, env.GOOGLE_CLIENT_ID);
  if (!g) return json({ error: 'bad_token' }, 401);
  const t = now();
  await env.DB.prepare(
    `INSERT INTO users (id, email, name, photo, first_seen, last_seen, app_version, status)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET email = excluded.email, name = excluded.name,
       photo = excluded.photo, last_seen = excluded.last_seen,
       app_version = coalesce(excluded.app_version, users.app_version)`)
    .bind(g.sub, g.email, clip(g.name, 200), clip(g.picture, 500), t, t, clip(body.appVersion, 40),
      // New people wait for the owner's OK while approval is on.
      env.APPROVAL === 'on' && g.email !== env.ADMIN_EMAIL ? 'pending' : 'active')
    .run();
  const user = await env.DB.prepare('SELECT * FROM users WHERE id = ?').bind(g.sub).first();
  if (user.status === 'banned') return json({ error: 'banned', reason: user.ban_reason || '' }, 403);

  const token = hex(crypto.getRandomValues(new Uint8Array(32)));
  let device = clip(body.device, 100);
  if (device === ADMIN_DEVICE && g.email !== env.ADMIN_EMAIL) device = 'Unknown phone';
  await env.DB.batch([
    env.DB.prepare('DELETE FROM sessions WHERE expires_at < ?').bind(t),
    // The same phone signing in again replaces its old sign-ins (one whose
    // sign-out never reached us would otherwise count as a phone for months).
    env.DB.prepare('DELETE FROM sessions WHERE user_id = ? AND device IS ?').bind(g.sub, device),
    env.DB.prepare(
      `INSERT INTO sessions (token_hash, user_id, device, created_at, expires_at, last_used)
       VALUES (?, ?, ?, ?, ?, ?)`)
      .bind(await sha256Hex(token), g.sub, device, t, t + SESSION_DAYS * 86400_000, t),
  ]);
  return json({ token, user: publicUser(user, env) });
}

const publicUser = (u, env) => ({
  id: u.id, email: u.email, name: u.name, photo: u.photo, status: u.status,
  admin: u.email === env.ADMIN_EMAIL,
});

// ---- Sync: newest snapshot wins, per kind (the app merges before it uploads) ----

// ?library=<ms>&history=<ms>...: a kind not newer than the time the phone
// already has comes back without its data, so syncs stay small.
async function getSync(req, env, user) {
  const have = Object.fromEntries(new URL(req.url).searchParams);
  const { results } = await env.DB.prepare(
    'SELECT kind, json, updated_at FROM user_data WHERE user_id = ?').bind(user.id).all();
  const out = {};
  for (const r of results) {
    out[r.kind] = Number(have[r.kind]) >= r.updated_at
      ? { updatedAt: r.updated_at }
      : { data: JSON.parse(r.json), updatedAt: r.updated_at };
  }
  return json(out);
}

async function putSync(req, env, user) {
  const body = await req.json().catch(() => null);
  if (!body || typeof body !== 'object') return json({ error: 'bad_body' }, 400);
  const writes = [];
  const { results: rows } = await env.DB.prepare(
    "SELECT kind FROM user_data WHERE user_id = ? AND kind LIKE 'listening:%'").bind(user.id).all();
  const phones = new Set(rows.map((r) => r.kind));
  for (const [kind, snap] of Object.entries(body)) {
    if (!KIND.test(kind) || !snap) continue;
    const listening = kind.startsWith('listening:');
    if (listening && !phones.has(kind)) {
      phones.add(kind);
      if (phones.size > MAX_PHONES) return json({ error: 'too_many_phones' }, 413);
    }
    const text = JSON.stringify(snap.data ?? null);
    const size = new TextEncoder().encode(text).length;
    if (size > (listening ? MAX_LISTENING : MAX_SNAPSHOT)) return json({ error: 'too_big', kind }, 413);
    const at = Number(snap.updatedAt);
    if (!Number.isFinite(at) || at <= 0) return json({ error: 'bad_time', kind }, 400);
    // A phone whose clock runs ahead must not win every future sync.
    // The phone cap is checked again inside the write itself, so parallel
    // requests can't each squeeze in a new phone.
    writes.push(env.DB.prepare(
      `INSERT INTO user_data (user_id, kind, json, updated_at)
       SELECT ?1, ?2, ?3, ?4
       WHERE ?2 NOT LIKE 'listening:%'
          OR EXISTS (SELECT 1 FROM user_data WHERE user_id = ?1 AND kind = ?2)
          OR (SELECT count(*) FROM user_data WHERE user_id = ?1 AND kind LIKE 'listening:%') < ?5
       ON CONFLICT(user_id, kind) DO UPDATE SET json = excluded.json, updated_at = excluded.updated_at
       WHERE excluded.updated_at > user_data.updated_at`)
      .bind(user.id, kind, text, Math.min(at, now()), MAX_PHONES));
  }
  if (writes.length) await env.DB.batch(writes);
  const { results } = await env.DB.prepare(
    'SELECT kind, updated_at FROM user_data WHERE user_id = ?').bind(user.id).all();
  return json({ updatedAt: Object.fromEntries(results.map((r) => [r.kind, r.updated_at])) });
}

// ---- Settings › Report a problem ----

/** Problem reports one person can send in 24 h. */
export const PROBLEMS_PER_DAY = 5;

async function reportProblem(req, env, user) {
  const body = await req.json().catch(() => null);
  const text = clip(String(body?.text ?? '').trim(), 2000);
  if (!text) return json({ error: 'bad_body' }, 400);
  const at = now();
  // The cap is checked inside the insert, like Jarvix reports.
  const put = await env.DB.prepare(
    `INSERT INTO problem_reports (user_id, at, text, app, device)
     SELECT ?, ?, ?, ?, ?
     WHERE (SELECT count(*) FROM problem_reports WHERE user_id = ? AND at > ?) < ?`)
    .bind(user.id, at, text, clip(req.headers.get('x-jarx-version'), 40), clip(body.device, 120),
      user.id, at - 86400_000, PROBLEMS_PER_DAY)
    .run();
  if (!put?.meta?.changes) return json({ error: 'too_many_reports' }, 429);
  await env.DB.prepare(
    'DELETE FROM problem_reports WHERE id NOT IN (SELECT id FROM problem_reports ORDER BY id DESC LIMIT 500)').run();
  return json({ ok: true });
}

async function listProblems(env) {
  const { results } = await env.DB.prepare(
    `SELECT p.at, p.text, p.app, p.device, u.email FROM problem_reports p LEFT JOIN users u ON u.id = p.user_id
     ORDER BY p.id DESC LIMIT 50`).all();
  return json({ problems: results });
}

// ---- Admin ----

async function listUsers(env, admin) {
  const { results } = await env.DB.prepare(
    `SELECT u.id, u.email, u.name, u.photo, u.first_seen, u.last_seen, u.app_version,
            u.status, u.ban_reason, u.id = ? AS self,
            (SELECT count(DISTINCT s.device) FROM sessions s
              WHERE s.user_id = u.id AND s.expires_at > ? AND s.device IS NOT ?) AS phones
     FROM users u ORDER BY u.last_seen DESC`)
    .bind(admin.id, now(), ADMIN_DEVICE).all();
  // Every phone that is signed in (rowid = its id for "Sign out this phone").
  const sessions = (await env.DB.prepare(
    `SELECT rowid AS sid, user_id, device, created_at, expires_at, last_used,
            token_hash = ? AS current
     FROM sessions WHERE expires_at > ? ORDER BY coalesce(last_used, created_at) DESC`)
    .bind(admin.token_hash, now()).all()).results;
  for (const u of results) {
    u.sessions = sessions.filter((s) => s.user_id === u.id)
      .map(({ user_id, ...s }) => ({ ...s, admin: s.device === ADMIN_DEVICE }));
  }
  const chats = await env.DB.prepare('SELECT coalesce(sum(chats), 0) AS n FROM ai_usage WHERE day = ?')
    .bind(ai.today()).first();
  const day = now() - 86400_000;
  return json({
    users: results,
    stats: {
      users: results.length,
      activeToday: results.filter((u) => u.last_seen > day).length,
      phones: results.reduce((n, u) => n + u.phones, 0),
      pending: results.filter((u) => u.status === 'pending').length,
      banned: results.filter((u) => u.status === 'banned').length,
      aiChatsToday: chats?.n ?? 0,
    },
  });
}

/** Signs out one phone (sid) or all of a user's phones (id), never the
 *  admin page's own sign-in. */
async function signOutPhones(req, env, admin) {
  const body = await req.json().catch(() => ({}));
  if (Number.isInteger(body.sid)) {
    await env.DB.prepare('DELETE FROM sessions WHERE rowid = ? AND token_hash IS NOT ?')
      .bind(body.sid, admin.token_hash).run();
  } else if (typeof body.id === 'string' && body.id) {
    await env.DB.prepare('DELETE FROM sessions WHERE user_id = ? AND token_hash IS NOT ?')
      .bind(body.id, admin.token_hash).run();
  } else {
    return json({ error: 'bad_request' }, 400);
  }
  return json({ ok: true });
}

async function setStatus(req, env, admin, status) {
  const body = await req.json().catch(() => ({}));
  if (!body.id || body.id === admin.id) return json({ error: 'bad_user' }, 400);
  const banned = status === 'banned';
  await env.DB.prepare('UPDATE users SET status = ?, ban_reason = ? WHERE id = ?')
    .bind(status, banned ? clip(body.reason, 300) || '' : null, body.id).run();
  return json({ ok: true });
}

// ---- Routes ----

async function route(req, env) {
  const path = req.method + ' ' + new URL(req.url).pathname;
  if (path === 'GET /favicon.png' || path === 'GET /favicon.ico') {
    return new Response(Uint8Array.from(atob(FAVICON_PNG_B64), (c) => c.charCodeAt(0)), {
      headers: { 'content-type': 'image/png', 'cache-control': 'public, max-age=604800' } });
  }
  const page = { 'GET /': HOME_PAGE, 'GET /privacy': PRIVACY_PAGE, 'GET /admin': path === 'GET /admin' && adminPage(env) }[path];
  if (page) return new Response(page, { headers: { 'content-type': 'text/html; charset=utf-8', ...PAGE_HEADERS } });
  if (path === 'POST /auth/google') return signIn(req, env);

  const user = await sessionUser(req, env);
  if (!user) return json({ error: 'signed_out' }, 401);
  // Banned or waiting for approval: may only leave (sign out, delete the account).
  const leaving = path === 'POST /signout' || path === 'DELETE /me';
  if (user.status === 'banned' && !leaving) return json({ error: 'banned', reason: user.ban_reason || '' }, 403);
  if (user.status === 'pending' && !leaving) return json({ error: 'pending' }, 403);
  const isAdmin = user.email === env.ADMIN_EMAIL;

  switch (path) {
    case 'GET /me':
      await env.DB.batch([
        env.DB.prepare('UPDATE users SET last_seen = ?, app_version = coalesce(?, app_version) WHERE id = ?')
          .bind(now(), clip(req.headers.get('x-jarx-version'), 40), user.id),
        env.DB.prepare('UPDATE sessions SET last_used = ? WHERE token_hash = ?').bind(now(), user.token_hash),
      ]);
      return json({ user: publicUser(user, env) });
    case 'POST /signout':
      await env.DB.prepare('DELETE FROM sessions WHERE token_hash = ?').bind(user.token_hash).run();
      return json({ ok: true });
    case 'DELETE /me':
      await env.DB.batch(['user_data', 'sessions', 'ai_usage', 'ai_reports', 'problem_reports'].map((t) =>
        env.DB.prepare(`DELETE FROM ${t} WHERE user_id = ?`).bind(user.id))
        .concat(user.status === 'banned'
          // A ban outlives the account: keep a bare record so signing in
          // again is refused (name and photo are dropped).
          ? env.DB.prepare('UPDATE users SET name = NULL, photo = NULL WHERE id = ?').bind(user.id)
          : env.DB.prepare('DELETE FROM users WHERE id = ?').bind(user.id)));
      return json({ ok: true });
    case 'GET /sync':
      return getSync(req, env, user);
    case 'PUT /sync':
      return putSync(req, env, user);
    case 'POST /ai/chat':
      return ai.chat(req, env, user);
    case 'POST /ai/tags':
      return ai.tags(req, env, user);
    case 'POST /ai/report':
      return ai.report(req, env, user);
    case 'POST /report':
      return reportProblem(req, env, user);
    case 'GET /admin/problems':
      return isAdmin ? listProblems(env) : json({ error: 'not_admin' }, 403);
    case 'GET /admin/reports':
      return isAdmin ? ai.listReports(env) : json({ error: 'not_admin' }, 403);
    case 'GET /admin/users':
      return isAdmin ? listUsers(env, user) : json({ error: 'not_admin' }, 403);
    case 'POST /admin/signout-phones':
      return isAdmin ? signOutPhones(req, env, user) : json({ error: 'not_admin' }, 403);
    case 'POST /admin/ban':
    case 'POST /admin/unban':
    case 'POST /admin/approve':
      if (!isAdmin) return json({ error: 'not_admin' }, 403);
      return setStatus(req, env, user, path.endsWith('/ban') ? 'banned' : 'active');
  }
  return json({ error: 'not_found' }, 404);
}

export default {
  async fetch(req, env) {
    try {
      // ponytail: one limit per address for everything; a shared Wi-Fi with
      // many JARX users stays far below it.
      if (env.LIMITER) {
        const ip = req.headers.get('cf-connecting-ip') || 'unknown';
        if (!(await env.LIMITER.limit({ key: ip })).success) return json({ error: 'slow_down' }, 429);
      }
      const res = await route(req, env);
      res.headers.set('x-content-type-options', 'nosniff');
      return res;
    } catch (e) {
      console.error(e);
      return json({ error: 'server' }, 500);
    }
  },
};

// ---- The owner's page: sign in with Google, see everyone and their phones ----

function adminPage(env) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>JARX Console</title>
<link rel="icon" type="image/png" href="/favicon.png">
<script src="https://accounts.google.com/gsi/client" async></script>
<style>
:root{--bg:#0a040c;--panel:#140c18;--panel2:#1b1120;--line:#2a1d30;--text:#daeaf7;--muted:#9a8fa3;
--blue:#0ea5e0;--blue2:#18c9ed;--pink:#fe385e;--green:#3ddc84;--amber:#ffb020}
*{box-sizing:border-box}
body{margin:0;background:radial-gradient(1200px 600px at 10% -10%,#2a0f2a 0,transparent 60%),var(--bg);
color:var(--text);font:14.5px/1.5 "Segoe UI",system-ui,sans-serif;min-height:100vh}
button{font:inherit;cursor:pointer;border:0;border-radius:10px;padding:8px 14px;font-weight:600}
input{font:inherit}
.top{position:sticky;top:0;z-index:5;display:flex;align-items:center;gap:12px;padding:14px 24px;
background:rgba(10,4,12,.82);backdrop-filter:blur(10px);border-bottom:1px solid var(--line)}
.top img.logo{width:34px;height:34px;border-radius:9px}
.top h1{margin:0;font-size:18px;letter-spacing:.2px}
.top h1 span{background:linear-gradient(90deg,var(--blue2),var(--pink));-webkit-background-clip:text;background-clip:text;color:transparent}
.top .sp{flex:1}
.me{display:flex;align-items:center;gap:10px;color:var(--muted);font-size:13px}
.me img{width:30px;height:30px;border-radius:50%}
.ghost{background:transparent;border:1px solid var(--line);color:var(--text)}
.ghost:hover{border-color:var(--blue)}
main{max-width:1180px;margin:0 auto;padding:22px 24px 60px}
.signin{max-width:380px;margin:12vh auto;text-align:center;background:var(--panel);border:1px solid var(--line);
border-radius:22px;padding:34px 28px}
.signin img{width:64px;height:64px;border-radius:16px}
.signin h2{margin:14px 0 4px}
.signin p{color:var(--muted);margin:0 0 22px}
.g_id_signin{display:flex;justify-content:center}
.stats{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:12px;margin-bottom:22px}
.stat{background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:14px 16px}
.stat b{display:block;font-size:26px;line-height:1.2}
.stat span{color:var(--muted);font-size:12.5px}
.stat.pink b{color:var(--pink)}.stat.blue b{color:var(--blue2)}.stat.amber b{color:var(--amber)}
.bar{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin-bottom:14px}
.search{flex:1;min-width:220px;background:var(--panel);border:1px solid var(--line);color:var(--text);
border-radius:12px;padding:10px 14px;outline:none}
.search:focus{border-color:var(--blue)}
.chip{background:var(--panel);border:1px solid var(--line);color:var(--muted);border-radius:20px;padding:6px 14px}
.chip.on{background:rgba(14,165,224,.15);border-color:var(--blue);color:var(--blue2)}
h2.sec{font-size:15px;letter-spacing:.06em;text-transform:uppercase;color:var(--muted);margin:30px 0 12px}
.user{background:var(--panel);border:1px solid var(--line);border-radius:16px;margin-bottom:10px;overflow:hidden}
.user .row{display:flex;align-items:center;gap:14px;padding:14px 16px}
.user .av{width:44px;height:44px;border-radius:50%;background:linear-gradient(135deg,var(--blue),var(--pink));
display:grid;place-items:center;font-weight:700;color:#fff;flex:none;overflow:hidden}
.user .av img{width:100%;height:100%;object-fit:cover}
.who{flex:1;min-width:0}
.who .n{font-weight:700;font-size:15px}
.who .e{color:var(--muted);font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.meta{display:flex;gap:16px;color:var(--muted);font-size:12.5px;flex-wrap:wrap}
.meta b{color:var(--text);font-weight:600}
.pill{font-size:12px;font-weight:700;padding:3px 10px;border-radius:20px;white-space:nowrap}
.pill.active{background:rgba(61,220,132,.14);color:var(--green)}
.pill.pending{background:rgba(255,176,32,.14);color:var(--amber)}
.pill.banned{background:rgba(254,56,94,.15);color:var(--pink)}
.pill.you{background:rgba(14,165,224,.15);color:var(--blue2)}
.phonesbtn{background:var(--panel2);border:1px solid var(--line);color:var(--text);display:flex;gap:6px;align-items:center}
.phonesbtn .arr{transition:transform .2s}.open .phonesbtn .arr{transform:rotate(180deg)}
.acts{display:flex;gap:8px}
.ok{background:var(--green);color:#062}.ban{background:var(--pink);color:#fff}.unban{background:var(--panel2);color:var(--green);border:1px solid var(--green)}
.phones{display:none;border-top:1px solid var(--line);background:var(--panel2);padding:10px 16px 14px}
.open .phones{display:block}
.phone{display:grid;grid-template-columns:1.6fr 1fr 1fr 1fr auto;gap:12px;align-items:center;padding:10px 0;
border-bottom:1px dashed var(--line);font-size:13px}
.phone:last-of-type{border-bottom:0}
.phone .d{font-weight:600;display:flex;gap:8px;align-items:center}
.phone small{display:block;color:var(--muted);font-size:11.5px}
.tag{font-size:10.5px;padding:1px 7px;border-radius:8px;background:rgba(14,165,224,.15);color:var(--blue2)}
.tag.stale{background:rgba(255,176,32,.14);color:var(--amber)}
.mini{padding:6px 12px;font-size:12.5px;background:transparent;border:1px solid var(--pink);color:var(--pink)}
.mini:hover{background:rgba(254,56,94,.12)}
.phones .foot{display:flex;justify-content:space-between;align-items:center;margin-top:10px;color:var(--muted);font-size:12.5px}
.empty{color:var(--muted);padding:12px 0}
.report{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:14px 16px;margin-bottom:10px}
.report .h{display:flex;justify-content:space-between;color:var(--muted);font-size:12.5px;margin-bottom:8px}
.report .q{color:var(--muted)}.report .a{margin-top:6px;border-left:3px solid var(--pink);padding-left:10px}
.toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%) translateY(30px);opacity:0;
background:#22152a;border:1px solid var(--blue);color:var(--text);padding:10px 18px;border-radius:12px;transition:.25s}
.toast.show{opacity:1;transform:translateX(-50%)}
@media (max-width:760px){.meta{display:none}.phone{grid-template-columns:1fr auto}.phone .c{display:none}.top{padding:12px 14px}main{padding:16px 14px 50px}}
</style></head><body>
<div class="top">
  <img class="logo" src="/favicon.png" alt="">
  <h1><span>JARX</span> Console</h1>
  <div class="sp"></div>
  <div class="me" id="me" hidden><img id="meImg" alt="" referrerpolicy="no-referrer"><span id="meName"></span>
    <button class="ghost" id="out">Sign out</button></div>
</div>
<div id="g_id_onload" data-client_id="${env.GOOGLE_CLIENT_ID}" data-callback="signedIn" data-auto_select="true"></div>
<main>
  <div class="signin" id="signin" hidden>
    <img src="/favicon.png" alt="">
    <h2>Owner sign-in</h2>
    <p id="msg">Sign in with the JARX owner's Google account.</p>
    <div class="g_id_signin" data-theme="filled_black" data-shape="pill"></div>
  </div>
  <div id="app" hidden>
    <div class="stats" id="stats"></div>
    <div class="bar">
      <input class="search" id="q" placeholder="Search name, email or phone…">
      <button class="chip on" data-f="all">All</button>
      <button class="chip" data-f="active">Active</button>
      <button class="chip" data-f="pending">Waiting</button>
      <button class="chip" data-f="banned">Banned</button>
      <button class="ghost" id="reload">Refresh</button>
    </div>
    <div id="users"></div>
    <h2 class="sec">Problems reported</h2>
    <div id="problems"></div>
    <h2 class="sec">Reported Jarvix replies</h2>
    <div id="reports"></div>
  </div>
</main>
<div class="toast" id="toast"></div>
<script>
var token = sessionStorage.getItem('jarxAdmin');
var data = null, filter = 'all', openIds = {};
function $(id) { return document.getElementById(id); }
function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
function toast(t) { var x = $('toast'); x.textContent = t; x.classList.add('show'); clearTimeout(x._t); x._t = setTimeout(function () { x.classList.remove('show'); }, 2600); }
function ago(ms) {
  if (!ms) return 'never';
  var s = (Date.now() - ms) / 1000;
  if (s < 60) return 'just now';
  if (s < 3600) return Math.floor(s / 60) + ' min ago';
  if (s < 86400) return Math.floor(s / 3600) + ' h ago';
  if (s < 86400 * 30) return Math.floor(s / 86400) + ' d ago';
  return new Date(ms).toLocaleDateString();
}
function date(ms) { return ms ? new Date(ms).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' }) : ''; }
async function api(method, path, body) {
  var r = await fetch(path, { method: method, body: body && JSON.stringify(body),
    headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' } });
  var j = await r.json();
  if (!r.ok) throw new Error(j.error || r.status);
  return j;
}
function showSignIn(text) {
  $('app').hidden = true; $('me').hidden = true; $('signin').hidden = false;
  if (text) $('msg').textContent = text;
}
async function signedIn(resp) {
  var r = await fetch('/auth/google', { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ idToken: resp.credential, device: '${ADMIN_DEVICE}' }) });
  var j = await r.json();
  if (!r.ok) return showSignIn('Sign-in failed: ' + j.error);
  if (!j.user.admin) return showSignIn('This Google account is not the JARX owner.');
  token = j.token;
  sessionStorage.setItem('jarxAdmin', token);
  sessionStorage.setItem('jarxAdminMe', JSON.stringify(j.user));
  load();
}
$('out').onclick = async function () {
  try { await api('POST', '/signout'); } catch (e) {}
  sessionStorage.clear(); token = null;
  if (window.google) google.accounts.id.disableAutoSelect();
  showSignIn('Signed out.');
};
function stat(n, label, cls) { var d = el('div', 'stat ' + (cls || '')); d.append(el('b', '', n), el('span', '', label)); return d; }
async function load() {
  if (!token) return showSignIn();
  try { data = await api('GET', '/admin/users'); }
  catch (e) {
    sessionStorage.removeItem('jarxAdmin'); token = null;
    return showSignIn(e.message === 'not_admin' ? 'This Google account is not the JARX owner.' : 'Please sign in again.');
  }
  $('signin').hidden = true; $('app').hidden = false; $('me').hidden = false;
  var me = JSON.parse(sessionStorage.getItem('jarxAdminMe') || '{}');
  $('meName').textContent = me.name || me.email || 'Owner';
  if (me.photo) $('meImg').src = me.photo; else $('meImg').hidden = true;
  var s = data.stats, st = $('stats'); st.textContent = '';
  st.append(stat(s.users, 'Users'), stat(s.activeToday, 'Active today', 'blue'), stat(s.phones, 'Phones signed in'),
    stat(s.pending, 'Waiting for approval', 'amber'), stat(s.banned, 'Banned', 'pink'), stat(s.aiChatsToday, 'Jarvix chats today', 'blue'));
  render();
  var pr = await api('GET', '/admin/problems').catch(function () { return { problems: [] }; });
  var pbox = $('problems'); pbox.textContent = '';
  if (!pr.problems.length) pbox.append(el('div', 'empty', 'No problems reported.'));
  pr.problems.forEach(function (x) {
    var c = el('div', 'report'), h = el('div', 'h');
    h.append(el('span', '', x.email || ''), el('span', '', ago(x.at)));
    c.append(h, el('div', 'a', x.text), el('div', 'q', [x.app && 'JARX ' + x.app, x.device].filter(Boolean).join(' · ')));
    pbox.append(c);
  });
  var r = await api('GET', '/admin/reports').catch(function () { return { reports: [] }; });
  var box = $('reports'); box.textContent = '';
  if (!r.reports.length) box.append(el('div', 'empty', 'Nothing reported. Jarvix is behaving.'));
  r.reports.forEach(function (x) {
    var c = el('div', 'report'), h = el('div', 'h');
    h.append(el('span', '', x.email || ''), el('span', '', ago(x.at)));
    c.append(h, el('div', 'q', x.said ? 'They said: ' + x.said : ''), el('div', 'a', x.reply));
    box.append(c);
  });
}
function statusPill(u) {
  if (u.self) return el('span', 'pill you', 'You');
  return u.status === 'banned' ? el('span', 'pill banned', 'Banned')
    : u.status === 'pending' ? el('span', 'pill pending', 'Waiting') : el('span', 'pill active', 'Active');
}
async function act(path, body, done) { try { await api('POST', path, body); toast(done); await load(); } catch (e) { toast('Failed: ' + e.message); } }
function render() {
  var q = $('q').value.trim().toLowerCase(), list = $('users'); list.textContent = '';
  var users = data.users.filter(function (u) {
    if (filter !== 'all' && u.status !== filter) return false;
    if (!q) return true;
    var hay = [u.name, u.email].concat(u.sessions.map(function (x) { return x.device; })).join(' ').toLowerCase();
    return hay.indexOf(q) >= 0;
  });
  if (!users.length) list.append(el('div', 'empty', 'No one matches.'));
  users.forEach(function (u) {
    var card = el('div', 'user' + (openIds[u.id] ? ' open' : '')), row = el('div', 'row');
    var av = el('div', 'av');
    if (u.photo) { var im = new Image(); im.referrerPolicy = 'no-referrer'; im.src = u.photo; av.append(im); }
    else av.textContent = (u.name || u.email || '?')[0].toUpperCase();
    var who = el('div', 'who'), n = el('div', 'n', (u.name || '(no name)') + ' ');
    n.append(statusPill(u));
    who.append(n, el('div', 'e', u.email));
    if (u.status === 'banned' && u.ban_reason) who.append(el('div', 'e', 'Reason: ' + u.ban_reason));
    var meta = el('div', 'meta');
    [['Version', u.app_version || '–'], ['Last seen', ago(u.last_seen)], ['Joined', date(u.first_seen)]].forEach(function (m) {
      var d = el('div', '', m[0] + ' '); d.append(el('b', '', m[1])); meta.append(d);
    });
    var pb = el('button', 'phonesbtn');
    pb.append(el('span', '', u.phones + (u.phones === 1 ? ' phone' : ' phones')), el('span', 'arr', '▾'));
    pb.onclick = function () { openIds[u.id] = !openIds[u.id]; card.classList.toggle('open'); };
    var acts = el('div', 'acts');
    if (!u.self) {
      if (u.status === 'pending') { var a = el('button', 'ok', 'Approve'); a.onclick = function () { act('/admin/approve', { id: u.id }, 'Approved'); }; acts.append(a); }
      if (u.status === 'banned') { var b = el('button', 'unban', 'Unban'); b.onclick = function () { act('/admin/unban', { id: u.id }, 'Unbanned'); }; acts.append(b); }
      else { var c = el('button', 'ban', 'Ban'); c.onclick = function () {
        var reason = prompt('Reason shown to ' + (u.name || u.email) + ':'); if (reason === null) return;
        act('/admin/ban', { id: u.id, reason: reason }, 'Banned'); }; acts.append(c); }
    }
    row.append(av, who, meta, pb, acts);
    var ph = el('div', 'phones');
    var phones = u.sessions.filter(function (x) { return !x.admin; });
    if (!phones.length) ph.append(el('div', 'empty', 'No phone is signed in.'));
    phones.forEach(function (x) {
      var p = el('div', 'phone'), d = el('div', 'd', x.device || 'Unknown phone');
      if (x.last_used && Date.now() - x.last_used > 30 * 86400000) d.append(el('span', 'tag stale', 'not used 30+ days'));
      var c1 = el('div', 'c'); c1.append(el('small', '', 'Signed in'), document.createTextNode(date(x.created_at)));
      var c2 = el('div', ''); c2.append(el('small', '', 'Last used'), document.createTextNode(x.last_used ? ago(x.last_used) : 'not since 22 Nov'));
      var c3 = el('div', 'c'); c3.append(el('small', '', 'Sign-in ends'), document.createTextNode(date(x.expires_at)));
      var out = el('button', 'mini', 'Sign out');
      out.onclick = function () {
        if (confirm('Sign out "' + (x.device || 'this phone') + '" for ' + (u.name || u.email) + '? JARX on that phone asks them to sign in again.'))
          act('/admin/signout-phones', { sid: x.sid }, 'Phone signed out');
      };
      p.append(d, c1, c2, c3, out); ph.append(p);
    });
    if (phones.length > 1) {
      var f = el('div', 'foot'), all = el('button', 'mini', 'Sign out all phones');
      f.append(el('span', '', 'Phones count by name; a phone signing in again replaces its old sign-in.'), all);
      all.onclick = function () {
        if (confirm('Sign out all ' + phones.length + ' phones of ' + (u.name || u.email) + '?'))
          act('/admin/signout-phones', { id: u.id }, 'All phones signed out');
      };
      ph.append(f);
    }
    card.append(row, ph); list.append(card);
  });
}
$('q').oninput = render;
document.querySelectorAll('.chip').forEach(function (c) {
  c.onclick = function () {
    document.querySelectorAll('.chip').forEach(function (x) { x.classList.remove('on'); });
    c.classList.add('on'); filter = c.dataset.f; render();
  };
});
$('reload').onclick = function () { load().then(function () { toast('Up to date'); }); };
load();
</script>
</body></html>`;
}

// No framing by other sites, scripts only from here and Google's sign-in.
const PAGE_HEADERS = {
  'content-security-policy': [
    "default-src 'self'",
    "script-src 'self' 'unsafe-inline' https://accounts.google.com/gsi/client",
    "style-src 'self' 'unsafe-inline' https://accounts.google.com/gsi/style",
    'frame-src https://accounts.google.com/gsi/',
    "connect-src 'self' https://accounts.google.com/gsi/",
    'img-src https: data:',
    "frame-ancestors 'none'",
  ].join('; '),
  'x-frame-options': 'DENY',
  'referrer-policy': 'no-referrer',
  'cross-origin-opener-policy': 'same-origin-allow-popups',
};

// ---- Public pages Google asks for (homepage, privacy policy) ----

const STYLE = `<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="icon" type="image/png" href="/favicon.png">
<style>body{font:16px/1.6 system-ui,sans-serif;max-width:720px;margin:0 auto;padding:24px 16px;background:#121212;color:#eee}
a{color:#ff7ab6}h1{font-size:26px}h2{font-size:19px;margin-top:28px}</style>`;

const HOME_PAGE = `<!doctype html><html><head>${STYLE}<title>JARX</title></head><body>
<h1>JARX</h1>
<p>JARX is a free music player for Android, made by Arnav Jaiswal. It is open source
(GPL-2.0), built on BloomeeTunes:
<a href="https://github.com/SofDev007/Jaiswal-audio">github.com/SofDev007/Jaiswal-audio</a>.</p>
<p>You sign in with Google so your playlists, Liked songs and what JARX learned about
your taste follow you to any phone.</p>
<p><a href="/privacy">Privacy policy</a> · Contact: arnavjaiswal.aj@gmail.com</p>
</body></html>`;

const PRIVACY_PAGE = `<!doctype html><html><head>${STYLE}<title>JARX privacy policy</title></head><body>
<h1>JARX privacy policy</h1>
<p>Last updated 22 November 2026. JARX is run by Arnav Jaiswal (arnavjaiswal.aj@gmail.com).</p>

<h2>What JARX stores about you</h2>
<ul>
<li><b>From your Google account:</b> your Google account id, email address, name and
profile photo. JARX never sees your Google password.</li>
<li><b>Your music:</b> your playlists, Liked songs, what JARX learned about your taste
(artists, languages and moods you play, and when), and how long you have listened.</li>
<li><b>Your phones:</b> the phone model name, the JARX version, and when you first and
last used JARX.</li>
</ul>

<h2>Why</h2>
<p>To sign you in, to bring your music back on another phone, to suggest songs you
will like, and so the owner can stop accounts that misuse JARX.</p>

<h2>Where it is kept</h2>
<p>On a server run on Cloudflare (Cloudflare Workers and D1). Connections are encrypted
(HTTPS). Your sign-in on the phone is kept in Android's secure storage.</p>

<h2>Who sees it</h2>
<p>Only you and the owner of JARX. It is not sold, not used for ads and not given to
anyone else, unless the law requires it.</p>

<h2>Other services JARX talks to</h2>
<p>Songs, pictures and lyrics come from music services through JARX plugins, which
contact those services directly from your phone (for example YouTube). JARX looks up
your country from your internet address to choose plugins that work there, and
downloads plugins from GitHub. Those services have their own privacy policies.</p>

<h2>JARX AI (Jarvix)</h2>
<p>Jarvix, the music buddy in JARX, is off until you turn it on. When you chat with it,
your messages go through the JARX server to an outside AI service (Groq, OpenRouter or
Cloudflare Workers AI) to get a reply. Some free AI services may use what they receive
to improve their products. With each message JARX sends what helps pick music: the song
playing, songs you played recently, your top artists, your languages, the names and
songs of your playlists, and the short notes Jarvix keeps about your taste. Your name,
email and contacts are never sent. Your chats and Jarvix's notes stay on your phone;
the server does not store chats. It only counts messages per day (for the daily limit)
and keeps replies you report, so the owner can check them. To tag songs with moods,
JARX also sends song titles, artists and albums (nothing about you); those tags are
shared by everyone.</p>

<h2>Report a problem</h2>
<p>When you send a problem from Settings › Report a problem, the server keeps what you
wrote with your JARX version and phone model, so the owner can fix it.</p>

<h2>Deleting your data</h2>
<p>In JARX, open Settings › Account › Delete my account. That removes everything above
from the server at once. You can also email arnavjaiswal.aj@gmail.com and ask for
deletion. Signing out keeps your music on the phone but ends that phone's sign-in.</p>

<h2>Children</h2>
<p>JARX is not meant for children under 13.</p>

<h2>Changes</h2>
<p>If this policy changes, the new version will be posted here with a new date.</p>
</body></html>`;
