// End-to-end check of the Worker with a real SQLite database (node:sqlite)
// and a fake Google key. Run: node test.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import worker from './src/index.js';

// D1's API over node:sqlite.
const db = new DatabaseSync(':memory:');
db.exec(readFileSync(new URL('./schema.sql', import.meta.url), 'utf8'));
const stmt = (sql, args = []) => ({
  bind: (...a) => stmt(sql, a),
  first: async () => db.prepare(sql).get(...args) ?? null,
  all: async () => ({ results: db.prepare(sql).all(...args) }),
  run: async () => ({ success: true, meta: { changes: Number(db.prepare(sql).run(...args).changes) } }),
});
const env = {
  DB: { prepare: (sql) => stmt(sql), batch: async (list) => { for (const s of list) await s.run(); } },
  GOOGLE_CLIENT_ID: 'cid', ADMIN_EMAIL: 'owner@x.com',
};

// A fake Google: our own key pair, served as Google's certs.
const pair = await crypto.subtle.generateKey(
  { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
  true, ['sign', 'verify']);
const jwk = { ...(await crypto.subtle.exportKey('jwk', pair.publicKey)), kid: 'k1', alg: 'RS256', use: 'sig' };
globalThis.fetch = async () => Response.json({ keys: [jwk] }, { headers: { 'cache-control': 'max-age=60' } });
const b64 = (x) => Buffer.from(typeof x === 'string' ? x : new Uint8Array(x)).toString('base64url');
async function googleToken(claims) {
  const head = b64(JSON.stringify({ alg: 'RS256', kid: 'k1' }));
  const body = b64(JSON.stringify({
    iss: 'https://accounts.google.com', aud: 'cid', exp: Date.now() / 1000 + 600, email_verified: true, ...claims }));
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', pair.privateKey, new TextEncoder().encode(head + '.' + body));
  return head + '.' + body + '.' + b64(sig);
}

async function call(method, path, { token, body, version } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (token) headers.authorization = 'Bearer ' + token;
  if (version) headers['x-jarx-version'] = version;
  const res = await worker.fetch(new Request('https://jarx.test' + path,
    { method, headers, body: body && JSON.stringify(body) }), env);
  return { status: res.status, body: res.headers.get('content-type').includes('json') ? await res.json() : await res.text() };
}
const signIn = async (claims, device = 'realme 5 Pro') =>
  call('POST', '/auth/google', { body: { idToken: await googleToken(claims), device, appVersion: '2.1.6+44' } });

const sis = { sub: 's1', email: 'sis@x.com', name: 'Sis', picture: 'https://p/s.jpg' };
const owner = { sub: 'o1', email: 'owner@x.com', name: 'Owner' };

// Bad tokens are refused.
assert.equal((await signIn({ ...sis, aud: 'other-app' })).status, 401, 'wrong app');
assert.equal((await signIn({ ...sis, exp: 1 })).status, 401, 'expired');
assert.equal((await signIn({ ...sis, email_verified: false })).status, 401, 'unverified email');
const good = await googleToken(sis);
const forged = good.slice(0, good.lastIndexOf('.') + 1) + b64('x'.repeat(256));
assert.equal((await call('POST', '/auth/google', { body: { idToken: forged } })).status, 401, 'bad signature');
assert.equal((await call('POST', '/auth/google', { body: { idToken: 'junk' } })).status, 401, 'junk');
assert.equal((await call('GET', '/me')).status, 401, 'no session');
assert.equal((await call('GET', '/me', { token: 'f'.repeat(64) })).status, 401, 'unknown session');

// Sign in, who am I.
const s = await signIn(sis);
assert.equal(s.status, 200);
assert.match(s.body.token, /^[0-9a-f]{64}$/);
assert.equal(s.body.user.admin, false);
const me = await call('GET', '/me', { token: s.body.token });
assert.equal(me.body.user.name, 'Sis');

// Sync: newest wins, a phone clock in the future is clamped.
const t = s.body.token;
await call('PUT', '/sync', { token: t, body: { library: { data: { playlists: ['A'] }, updatedAt: 100 } } });
await call('PUT', '/sync', { token: t, body: { library: { data: { playlists: ['old'] }, updatedAt: 50 } } });
let sync = await call('GET', '/sync', { token: t });
assert.deepEqual(sync.body.library, { data: { playlists: ['A'] }, updatedAt: 100 });
const put = await call('PUT', '/sync', { token: t, body: {
  library: { data: { playlists: ['B'] }, updatedAt: 200 }, taste: { data: { w: 1 }, updatedAt: Date.now() + 9e9 } } });
assert.ok(put.body.updatedAt.taste <= Date.now(), 'future clock clamped');
sync = await call('GET', '/sync', { token: t });
assert.deepEqual(sync.body.library.data, { playlists: ['B'] });
assert.deepEqual(sync.body.taste.data, { w: 1 });
assert.equal((await call('PUT', '/sync', { token: t, body: { taste: { data: 'x'.repeat(2e6), updatedAt: 1 } } })).status, 413);
assert.equal((await call('PUT', '/sync', { token: t, body: { taste: { data: 1, updatedAt: 'soon' } } })).status, 400);

// Only the owner sees the admin list.
assert.equal((await call('GET', '/admin/users', { token: t })).status, 403);
const o = await signIn(owner, 'admin page');
assert.equal(o.body.user.admin, true);
let users = (await call('GET', '/admin/users', { token: o.body.token })).body.users;
assert.equal(users.length, 2);
assert.equal(users.find((u) => u.id === 's1').phones, 1);
assert.equal(users.find((u) => u.id === 'o1').phones, 0, 'admin page is not a phone');
assert.equal((await call('POST', '/admin/ban', { token: o.body.token, body: { id: 'o1' } })).status, 400, 'no self-ban');

// Ban: the open session and new sign-ins are refused with the reason.
await call('POST', '/admin/ban', { token: o.body.token, body: { id: 's1', reason: 'spam' } });
assert.deepEqual((await call('GET', '/me', { token: t })).body, { error: 'banned', reason: 'spam' });
assert.equal((await signIn(sis)).status, 403);
users = (await call('GET', '/admin/users', { token: o.body.token })).body.users;
assert.equal(users.find((u) => u.id === 's1').status, 'banned');
await call('POST', '/admin/unban', { token: o.body.token, body: { id: 's1' } });
assert.equal((await call('GET', '/me', { token: t })).status, 200, 'unbanned');

// Sign out ends only that session; delete removes everything.
const t2 = (await signIn(sis, 'OPPO CPH2641')).body.token;
await call('POST', '/signout', { token: t2 });
assert.equal((await call('GET', '/me', { token: t2 })).status, 401);
assert.equal((await call('GET', '/me', { token: t })).status, 200);
await call('DELETE', '/me', { token: t });
assert.equal((await call('GET', '/me', { token: t })).status, 401);
const again = await signIn(sis);
assert.deepEqual((await call('GET', '/sync', { token: again.body.token })).body, {}, 'fresh after delete');

// Approval on: new people wait until the owner approves them.
env.APPROVAL = 'on';
const friend = { sub: 'f1', email: 'friend@x.com', name: 'Friend' };
const f = await signIn(friend);
assert.equal(f.status, 200);
assert.equal(f.body.user.status, 'pending');
assert.deepEqual((await call('GET', '/me', { token: f.body.token })).body, { error: 'pending' });
assert.equal((await call('GET', '/sync', { token: f.body.token })).status, 403);
assert.equal((await signIn(owner)).body.user.status, 'active', 'the owner never waits');
assert.equal((await signIn(sis, 'Pixel 8')).body.user.status, 'active', 'known users keep their status');
assert.equal((await call('POST', '/admin/approve', { token: again.body.token, body: { id: 'f1' } })).status, 403, 'only the owner approves');
await call('POST', '/admin/approve', { token: o.body.token, body: { id: 'f1' } });
assert.equal((await call('GET', '/me', { token: f.body.token })).status, 200, 'approved');

// One listening row per phone; unknown kinds ignored; unchanged kinds come back without data.
const ft = f.body.token;
await call('PUT', '/sync', { token: ft, body: {
  'listening:aaaaaaaa': { data: { totalMs: 1 }, updatedAt: 10 },
  'listening:bbbbbbbb': { data: { totalMs: 2 }, updatedAt: 20 },
  history: { data: [1], updatedAt: 30 },
  junk: { data: 1, updatedAt: 5 } } });
const s2 = (await call('GET', '/sync?history=30&listening:aaaaaaaa=0', { token: ft })).body;
assert.deepEqual(Object.keys(s2).sort(), ['history', 'listening:aaaaaaaa', 'listening:bbbbbbbb']);
assert.equal(s2.history.data, undefined, 'unchanged: no data');
assert.equal(s2.history.updatedAt, 30);
assert.equal(s2['listening:aaaaaaaa'].data.totalMs, 1);

// Listening rows: limited in size and in number of phones per account.
assert.equal((await call('PUT', '/sync', { token: ft, body: {
  'listening:cccccccc': { data: 'x'.repeat(300_000), updatedAt: 40 } } })).status, 413, 'listening too big');
for (let i = 0; i < 8; i++) {
  const r = await call('PUT', '/sync', { token: ft, body: {
    [`listening:${String(i).repeat(8)}`]: { data: { totalMs: i }, updatedAt: 50 } } });
  assert.equal(r.status, i < 8 ? 200 : 413);
}
const tooMany = await call('PUT', '/sync', { token: ft, body: {
  'listening:dddddddd': { data: { totalMs: 1 }, updatedAt: 60 } } });
assert.deepEqual([tooMany.status, tooMany.body.error], [413, 'too_many_phones'], '11th phone refused');
assert.equal((await call('PUT', '/sync', { token: ft, body: {
  'listening:aaaaaaaa': { data: { totalMs: 9 }, updatedAt: 70 } } })).status, 200, 'known phone still updates');

// A banned account may still sign out or delete itself, nothing else.
const b1 = (await signIn({ sub: 'b1', email: 'bad@x.com', name: 'Bad' })).body.token;
await call('POST', '/admin/approve', { token: o.body.token, body: { id: 'b1' } });
await call('POST', '/admin/ban', { token: o.body.token, body: { id: 'b1', reason: 'x' } });
assert.equal((await call('GET', '/sync', { token: b1 })).status, 403);
assert.equal((await call('DELETE', '/me', { token: b1 })).status, 200, 'banned can delete');
assert.equal((await signIn({ sub: 'b1', email: 'bad@x.com', name: 'Bad' })).status, 403, 'ban survives deleting the account');
assert.equal((await call('GET', '/sync', { token: b1 })).status, 401, 'its sessions are gone');

// Parallel uploads can't push an account past 10 phones.
const p1 = (await signIn({ sub: 'p1', email: 'p@x.com', name: 'P' })).body.token;
await call('POST', '/admin/approve', { token: o.body.token, body: { id: 'p1' } });
await Promise.all(Array.from({ length: 15 }, (_, i) => call('PUT', '/sync', { token: p1, body: {
  [`listening:${i.toString(16).padStart(8, 'a')}`]: { data: { totalMs: i }, updatedAt: 5 } } })));
assert.equal(db.prepare("SELECT count(*) AS n FROM user_data WHERE user_id = 'p1'").get().n, 10);

// Too many requests from one address are refused.
env.LIMITER = { limit: async () => ({ success: false }) };
assert.equal((await call('GET', '/me', { token: ft })).status, 429);
delete env.LIMITER;

// Phones: signing in again on the same phone replaces its old sign-in; the
// owner sees each phone and can sign out one or all of them.
const ph = { sub: 'ph1', email: 'phones@x.com', name: 'Phones' };
await signIn(ph, 'realme RMX1971');
await call('POST', '/admin/approve', { token: o.body.token, body: { id: 'ph1' } });
const old1 = (await signIn(ph, 'realme RMX1971')).body.token;
const fresh1 = (await signIn(ph, 'realme RMX1971')).body.token;
assert.equal((await call('GET', '/me', { token: old1 })).status, 401, 'old sign-in of the same phone replaced');
assert.equal((await call('GET', '/me', { token: fresh1 })).status, 200);
await signIn(ph, 'OPPO CPH2641');
let list = (await call('GET', '/admin/users', { token: o.body.token })).body;
let pu = list.users.find((u) => u.id === 'ph1');
assert.equal(pu.phones, 2);
assert.deepEqual(pu.sessions.map((x) => x.device).sort(), ['OPPO CPH2641', 'realme RMX1971']);
assert.ok(pu.sessions.every((x) => x.last_used > 0 && x.created_at > 0 && x.expires_at > x.created_at));
assert.equal(typeof list.stats.users, 'number');
assert.equal(typeof list.stats.aiChatsToday, 'number');
assert.equal((await call('POST', '/admin/signout-phones', { token: fresh1, body: { id: 'ph1' } })).status, 403, 'owner only');
const oppo = pu.sessions.find((x) => x.device === 'OPPO CPH2641');
await call('POST', '/admin/signout-phones', { token: o.body.token, body: { sid: oppo.sid } });
pu = (await call('GET', '/admin/users', { token: o.body.token })).body.users.find((u) => u.id === 'ph1');
assert.equal(pu.phones, 1, 'one phone signed out');
assert.equal((await call('GET', '/me', { token: fresh1 })).status, 200, 'the other phone stays');
await call('POST', '/admin/signout-phones', { token: o.body.token, body: { id: 'ph1' } });
assert.equal((await call('GET', '/me', { token: fresh1 })).status, 401, 'all phones signed out');
await call('POST', '/admin/signout-phones', { token: o.body.token, body: { id: 'o1' } });
assert.equal((await call('GET', '/admin/users', { token: o.body.token })).status, 200, "the admin page keeps its own sign-in");

// Only the owner's sign-in may be named "admin page" (it's hidden from the
// phone list); anyone else's is renamed, so no phone can hide.
const sneaky = { sub: 'sn1', email: 'sneaky@x.com', name: 'Sneaky' };
await signIn(sneaky, 'admin page');
await call('POST', '/admin/approve', { token: o.body.token, body: { id: 'sn1' } });
const sn = (await call('GET', '/admin/users', { token: o.body.token })).body.users.find((u) => u.id === 'sn1');
assert.equal(sn.phones, 1, 'a non-owner "admin page" counts as a phone');
assert.deepEqual(sn.sessions.map((x) => [x.device, x.admin]), [['Unknown phone', false]]);

// The favicon is served for every page.
const fav = await worker.fetch(new Request('https://jarx.test/favicon.png'), env);
assert.equal(fav.headers.get('content-type'), 'image/png');
assert.deepEqual([...new Uint8Array(await fav.arrayBuffer()).slice(1, 4)], [0x50, 0x4e, 0x47]);

// The admin page is served.
const page = await call('GET', '/admin');
assert.match(page.body, /data-client_id="cid"/);
const raw = await worker.fetch(new Request('https://jarx.test/admin'), env);
assert.equal(raw.headers.get('x-frame-options'), 'DENY');
assert.match(raw.headers.get('content-security-policy'), /frame-ancestors 'none'/);
assert.equal(raw.headers.get('x-content-type-options'), 'nosniff');
assert.equal((await call('GET', '/nope', { token: o.body.token })).status, 404);

// ---- JARX AI ----
// A fake Workers AI (no Groq/OpenRouter keys: it is the only provider).
let aiCalls = [];
let aiAnswer = () => '';
env.AI = { run: async (model, input) => { aiCalls.push(input); return { response: aiAnswer(input) }; } };
const say = (text, context) => call('POST', '/ai/chat', { token: ft, body: { messages: [{ role: 'user', content: text }], context } });

aiAnswer = () => 'Sure! ' + JSON.stringify({ reply: 'Hey {name}, try these', helpline: false, remember: ['gym in the evening'],
  mix: { title: 'Beast mode', moods: ['dance', 'nonsense'], fromPlaylists: ['Gym'], songs: [{ title: 'Brown Munde', artist: 'AP Dhillon' }, { title: '' }] } });
const c1 = await say('hype me up', { playing: 'Kesariya — Arijit Singh', playlists: { Gym: ['Excuses — AP Dhillon'] }, memory: ['likes Punjabi'] });
assert.equal(c1.status, 200);
assert.equal(c1.body.reply, 'Hey {name}, try these', 'the name placeholder is left for the phone');
assert.deepEqual(c1.body.mix.moods, ['dance'], 'unknown moods dropped');
assert.deepEqual(c1.body.mix.songs, [{ title: 'Brown Munde', artist: 'AP Dhillon' }], 'empty songs dropped');
const sys = aiCalls[0].messages[0].content;
assert.match(sys, /Excuses — AP Dhillon/, 'playlists reach the AI');
assert.match(sys, /Download one song: tap ⋮ next to the song, then Download/, 'the JARX guide reaches the AI');
assert.match(sys, /You are Jarvix,/, 'named Jarvix');
assert.match(sys, /likes Punjabi/, 'memory reaches the AI');
assert.doesNotMatch(sys, /friend@x\.com|Friend/, 'name and email never sent');

aiAnswer = () => JSON.stringify({ reply: "I'm here for you.", helpline: true, mix: null });
const c2 = await say('i feel really low');
assert.deepEqual([c2.body.helpline, c2.body.mix], [true, null]);
assert.equal((await call('POST', '/ai/chat', { token: ft, body: { messages: [] } })).status, 400, 'no message');

// Every provider down: 503, and it doesn't count.
aiAnswer = () => 'not json';
assert.equal((await say('hello')).status, 503);
assert.equal(db.prepare("SELECT chats FROM ai_usage WHERE user_id = 'f1'").get().chats, 2, 'failed call refunded');

// Daily limit.
env.AI_DAILY_LIMIT = '3';
aiAnswer = () => JSON.stringify({ reply: 'ok' });
assert.equal((await say('one more')).status, 200);
const lim = await say('and another');
assert.deepEqual([lim.status, lim.body.error], [429, 'ai_limit'], 'limit reached');
delete env.AI_DAILY_LIMIT;

// Build 43 fix: an answer without a reply is a failure (never a bare "🎶"),
// the reply is found under other keys, old "🎶" replies never reach the
// model again, and "play" passes through.
aiAnswer = () => JSON.stringify({ reply: '', mix: null });
const empty = await call('POST', '/ai/chat', { token: ft, body: { messages: [{ role: 'user', content: 'roast my taste' }] } });
assert.deepEqual([empty.status, empty.body.error], [503, 'ai_down'], 'empty reply = AI down, not 🎶');
aiAnswer = () => JSON.stringify({ message: 'Your taste? Pure Pritam at 2am.' });
aiCalls = [];
const alt = await call('POST', '/ai/chat', { token: ft, body: { messages: [
  { role: 'user', content: 'roast my taste' }, { role: 'assistant', content: '🎶' },
  { role: 'user', content: 'roast my taste' }] } });
assert.equal(alt.body.reply, 'Your taste? Pure Pritam at 2am.');
assert.ok(!aiCalls.at(-1).messages.some((m) => m.content === '🎶'), 'old 🎶 replies dropped');
aiAnswer = () => JSON.stringify({ reply: '', play: { title: 'Kesariya', artist: 'Arijit Singh' } });
const pl = await say('play kesariya');
assert.deepEqual(pl.body.play, { title: 'Kesariya', artist: 'Arijit Singh', video: false });
assert.equal(pl.body.reply, 'Playing it now. ▶');
assert.ok(!JSON.stringify((await say('hi')).body).includes('🎶'));
// Reports: 20 a day per person, then refused (others' reports stay).
// Sent all at once: the cap still holds.
await Promise.all(Array.from({ length: 25 }, (_, i) =>
  call('POST', '/ai/report', { token: p1, body: { said: 'x', reply: 'r' + i } })));
assert.equal(db.prepare("SELECT count(*) AS n FROM ai_reports WHERE user_id = 'p1'").get().n, 20, 'reports capped per person');
assert.equal((await call('POST', '/ai/report', { token: p1, body: { reply: 'one more' } })).status, 429);
aiAnswer = () => JSON.stringify({ reply: 'Here it is', play: { title: 'Aadat', artist: 'Jal', video: true } });
assert.equal((await say('show me the video of aadat')).body.play.video, true, 'video flag passes through');


// Mood tags: asked once, then shared from the cache; unknown songs stored empty.
aiCalls = [];
aiAnswer = () => JSON.stringify({ tags: { 0: ['sad', 'calm', 'weird'], 1: [] } });
const songs = [{ key: 'channa mereya|arijit singh', title: 'Channa Mereya', artist: 'Arijit Singh' },
  { key: 'unknown|nobody', title: 'Unknown', artist: 'Nobody' }];
const tg1 = await call('POST', '/ai/tags', { token: ft, body: { songs } });
assert.deepEqual(tg1.body.tags, { 'channa mereya|arijit singh': ['sad', 'calm'] });
const tg2 = await call('POST', '/ai/tags', { token: p1, body: { songs } });
assert.deepEqual(tg2.body.tags, tg1.body.tags, 'another user gets the cached tags');
assert.equal(aiCalls.length, 1, 'the AI was asked once');

// Reports reach the owner only; deleting the account removes its AI rows.
assert.equal((await call('POST', '/ai/report', { token: ft, body: { said: 'hi', reply: 'bad reply' } })).status, 200);
assert.equal((await call('GET', '/admin/reports', { token: ft })).status, 403, 'not the owner');
const reps = (await call('GET', '/admin/reports', { token: o.body.token })).body.reports;
assert.deepEqual([reps[0].reply, reps[0].email], ['bad reply', 'friend@x.com']);
await call('DELETE', '/me', { token: ft });
assert.equal(db.prepare("SELECT count(*) AS n FROM ai_usage WHERE user_id = 'f1'").get().n, 0);
assert.equal(db.prepare("SELECT count(*) AS n FROM ai_reports WHERE user_id = 'f1'").get().n, 0);
assert.match((await call('GET', '/privacy')).body, /JARX AI \(Jarvix\)/);
// Builds before 37 are locked out with an "update" reason; 37+ and apps
// that don't say their version are let in.
for (const v of ['2.0.0+36', '2.0.0+2036', '2.0.0+34']) {
  const r = await call('GET', '/me', { token: p1, version: v });
  assert.equal(r.status, 403, v);
  assert.equal(r.body.error, 'banned');
  assert.match(r.body.reason, /too old.*\/update/);
}
for (const v of ['2.0.0+37', '2.1.6+44', '2.0.0+2042', undefined]) {
  assert.equal((await call('GET', '/me', { token: p1, version: v })).status, 200, String(v));
}
assert.equal((await call('POST', '/signout', { token: p1, version: '2.0.0+36' })).status, 200, 'an old app can still sign out');
const oldSignIn = await call('POST', '/auth/google', {
  body: { idToken: await googleToken({ sub: 'z1', email: 'z@x.com' }), appVersion: '2.0.0+36' } });
assert.deepEqual([oldSignIn.status, oldSignIn.body.error], [403, 'banned'], 'an old app cannot sign in');
const upd = await worker.fetch(new Request('https://x/update'), env);
assert.equal(upd.status, 302);
assert.match(upd.headers.get('location'), /SofDev007\/JARX\/releases\/latest/);
console.log('all server checks passed');
