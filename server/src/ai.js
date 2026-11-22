// JARX AI ("Jarvix"): the companion chat, shared mood tags and reports of
// bad replies. The AI keys live only here (wrangler secrets GROQ_KEY and
// OPENROUTER_KEY); Cloudflare's own Workers AI (binding AI) needs no key and
// is the last fallback, so the chat works before any key is added.
// Model names are [vars] in wrangler.toml: change them without a new build.

export const MOODS = ['sad', 'romantic', 'happy', 'dance', 'cozy', 'moody',
  'uplifting', 'energetic', 'devotional', 'calm'];
export const AI_NAME = 'Jarvix';

const json = (body, status = 200) => Response.json(body, { status });
const clip = (v, n) => String(v ?? '').slice(0, n);
// Limits reset at midnight India time.
export const today = () => new Date(Date.now() + 5.5 * 3600_000).toISOString().slice(0, 10);

/** The first {...} in [text] as an object, or null. */
export function parseJson(text) {
  const s = String(text ?? '');
  const a = s.indexOf('{'), b = s.lastIndexOf('}');
  if (a < 0 || b <= a) return null;
  try {
    const j = JSON.parse(s.slice(a, b + 1));
    return j && typeof j === 'object' ? j : null;
  } catch {
    return null;
  }
}

async function openAiStyle(url, key, model, messages, maxTokens) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { authorization: 'Bearer ' + key, 'content-type': 'application/json' },
    body: JSON.stringify({ model, messages, max_tokens: maxTokens, temperature: 0.8,
      response_format: { type: 'json_object' } }),
    signal: AbortSignal.timeout(25_000),
  });
  if (!res.ok) throw new Error(`${new URL(url).host} ${res.status}`);
  return (await res.json()).choices?.[0]?.message?.content ?? '';
}

/** Groq, then OpenRouter, then Workers AI; the first JSON answer that
 *  [valid] accepts wins (a provider that answers badly counts as down). */
export async function complete(env, messages, maxTokens, valid = () => true) {
  const tries = [];
  if (env.GROQ_KEY) {
    tries.push(() => openAiStyle('https://api.groq.com/openai/v1/chat/completions',
      env.GROQ_KEY, env.GROQ_MODEL || 'llama-3.3-70b-versatile', messages, maxTokens));
  }
  if (env.OPENROUTER_KEY) {
    tries.push(() => openAiStyle('https://openrouter.ai/api/v1/chat/completions',
      env.OPENROUTER_KEY, env.OPENROUTER_MODEL || 'openrouter/free', messages, maxTokens));
  }
  if (env.AI) {
    tries.push(async () => {
      const r = await env.AI.run(env.CF_MODEL || '@cf/meta/llama-3.3-70b-instruct-fp8-fast',
        { messages, max_tokens: maxTokens });
      return typeof r?.response === 'string' ? r.response : JSON.stringify(r?.response ?? '');
    });
  }
  for (const t of tries) {
    try {
      const j = parseJson(await t());
      if (j && valid(j)) return j;
      if (j) console.error('ai provider gave an unusable answer');
    } catch (e) {
      console.error('ai provider failed:', e.message);
    }
  }
  return null;
}

/** Adds one to today's [what] count; false when that passes [limit]. */
async function spend(env, user, what, limit) {
  const row = await env.DB.prepare(
    `INSERT INTO ai_usage (user_id, day, ${what}) VALUES (?, ?, 1)
     ON CONFLICT(user_id, day) DO UPDATE SET ${what} = ${what} + 1 RETURNING ${what} AS n`)
    .bind(user.id, today()).first();
  return row.n <= limit;
}
const refund = (env, user, what) => env.DB.prepare(
  `UPDATE ai_usage SET ${what} = ${what} - 1 WHERE user_id = ? AND day = ?`).bind(user.id, today()).run();

const list = (v, n, len) => (Array.isArray(v) ? v : []).slice(0, n).map((x) => clip(x, len)).filter(Boolean);

/** How JARX works, so Jarvix can walk people through it. Kept on the
 *  server: fixing a step never needs a new app. Only what the app really
 *  has (checked against build 43). */
export const APP_GUIDE = `- Bottom bar: Home, Library, Search, Local, Offline. Settings: the gear at the top of Home.
- Play a song: Search, type the name, tap the song. The chips under the search box pick where to search (YouTube Music, YouTube Video, JioSaavn...).
- Download one song: tap ⋮ next to the song, then Download. A whole playlist: open it (Library), tap the Download button at the top. Downloaded songs are in the Offline tab, which also has Pause all and Cancel all. Download only on Wi-Fi: Settings › Downloads › Download over › Wi-Fi.
- Queue: swipe a song to the right to add it to the queue, or ⋮ › Add to queue / Play next. See what plays next: swipe up on the player. Close the player: swipe it down; the music keeps playing.
- Playlists: Library › + to make one; ⋮ on a song › Add to Playlist. Bring playlists from Spotify, YouTube Music or a CSV file: Library › the import button next to +.
- Like a song: the heart in the player. Liked songs are a playlist in Library.
- Shuffle: open a playlist, tap Shuffle, then Shuffle or Smart shuffle (Smart mixes in new songs you'll like; + keeps one in the playlist).
- Never suggest a song again: ⊖ next to a suggested song (Home, Up Next), or ⋮ › Do not suggest this song.
- Lyrics: the current line shows in the player; the lyrics button opens them all. Lyrics late or early: in the full lyrics, ⋮ › Sync lyrics, then tap the line the moment you hear it.
- Sleep timer: the timer button in the player. Repeat: the repeat button (all, one, off).
- Music videos: search with YouTube Video, play the song, tap Play video above its name. Full screen has captions (CC) and video quality in its settings. Or ask Jarvix: "show me the video of …".
- Equalizer: Settings › Player Settings › Equalizer.
- Change how Home looks: Settings › Home layout.
- Your corner (minutes listened, top artists this month): tap your photo on Home. Switch account: hold your photo, or Settings › Account.
- Playlists and Liked sync to every phone you sign in on, by themselves.
- Updates: the bell on Home shows a new version; tap Download update, then Install.
- Music sources (plugins): Settings › Plugins. They update by themselves.
- Songs stored on the phone: the Local tab.
- Jarvix: tap the blob. Ask for a mood or vibe (a mix), "play …" (that song at once, from their playlist if it's there), "show me the video of …". The ⋮ in the chat shows what Jarvix remembers, and can clear the chat.`;

/** The system prompt: who Jarvix is, and what the phone told us about the user. */
export function systemPrompt(ctx = {}) {
  const playlists = Object.entries(ctx.playlists && typeof ctx.playlists === 'object' ? ctx.playlists : {})
    .slice(0, 15)
    .map(([name, songs]) => `- "${clip(name, 60)}": ${list(songs, 25, 80).join('; ')}`);
  const about = [
    ctx.time && `Time there: ${clip(ctx.time, 60)}`,
    ctx.playing && `Playing now: ${clip(ctx.playing, 120)}`,
    ctx.languages && `Languages they like: ${list(ctx.languages, 6, 20).join(', ')}`,
    ctx.topArtists && `Top artists this month: ${list(ctx.topArtists, 10, 60).join(', ')}`,
    ctx.recent && `Recently played: ${list(ctx.recent, 20, 100).join('; ')}`,
    playlists.length && `Their own playlists:\n${playlists.join('\n')}`,
    ctx.memory && `What you remember about them: ${list(ctx.memory, 20, 120).join('; ')}`,
  ].filter(Boolean).join('\n');

  return `You are ${AI_NAME}, the music buddy inside JARX, a music app used mostly in India.
Personality: warm, funny, honest and a little cheeky, like a good friend. Never mean, never preachy.
Keep replies short: 1 to 3 sentences. Always write a real "reply", never an empty one or just an emoji. If they send the same message again, answer again in a fresh way. Reply in the language and script the user writes in (Hinglish if they write Hinglish).
You don't know the user's name. To use it, write exactly {name} and the app fills it in.
You only play music and music videos: you can't change settings, delete or download anything.
You are not a therapist. If the user sounds very low or hopeless, or mentions self-harm or suicide: be kind and calm, don't lecture, offer gentle music, and set "helpline": true (the app then shows a free helpline).

When they ask to play ONE specific song ("play Kesariya", "Tum Hi Ho chalao"), set "play" to that song ({"title", "artist"}, the artist if you know it), "mix": null, and reply in one short line. If they want its music video ("show me the video of Aadat"), also set "video": true in "play".
When they ask how to do something in JARX (download, playlists, lyrics, videos, settings...), guide them with short numbered steps (up to 6), only from the JARX guide below; no mix then. If the guide doesn't cover it, say you're not sure and point them to Settings. Never invent buttons or features.
When music would help (a mood, a vibe, an artist, "play something"), add a "mix" of 8 to 12 songs.
Build it mainly from the user's own playlists below (their songs that fit), plus a few well-known songs that fit their taste and languages.
Only real songs that exist on YouTube Music, with the correct main artist. Never invent songs. No mix when just chatting.

Answer ONLY with JSON, no other text:
{"reply": "...", "play": null or {"title": "...", "artist": "...", "video": false}, "mix": null or {"title": "short fun mix name", "moods": ["one or two of: ${MOODS.join(', ')}"], "fromPlaylists": ["names of their playlists you used"], "songs": [{"title": "...", "artist": "..."}]}, "helpline": false, "remember": []}
"remember": 0 to 2 short new facts about their music taste or habits worth remembering (like "gym in the evenings"), not already remembered. Never names, numbers, addresses or health details.

JARX guide (how the app works):
${APP_GUIDE}

About the user:
${about || 'Nothing yet.'}`;
}

/** The reply text, whatever key the model put it under. */
export const replyOf = (a) => {
  const r = a?.reply ?? a?.message ?? a?.response ?? a?.text ?? a?.answer;
  return typeof r === 'string' ? r.trim() : '';
};

/** Keeps only what the app understands from the model's answer. */
export function cleanAnswer(a) {
  const m = a.mix && typeof a.mix === 'object' ? a.mix : null;
  const songs = (Array.isArray(m?.songs) ? m.songs : [])
    .map((s) => ({ title: clip(s?.title, 100).trim(), artist: clip(s?.artist, 100).trim() }))
    .filter((s) => s.title)
    .slice(0, 12);
  const play = a.play && typeof a.play === 'object' && clip(a.play.title, 100).trim()
    ? { title: clip(a.play.title, 100).trim(), artist: clip(a.play.artist, 100).trim(),
        video: a.play.video === true } : null;
  return {
    reply: clip(replyOf(a), 1200)
      || (play ? 'Playing it now. ▶' : songs.length ? 'Here you go, {name}. 🎧' : ''),
    play,
    mix: songs.length ? {
      title: clip(m.title, 40).trim() || 'Your mix',
      moods: list(m.moods, 3, 20).map((x) => x.toLowerCase()).filter((x) => MOODS.includes(x)),
      fromPlaylists: list(m.fromPlaylists, 4, 60),
      songs,
    } : null,
    helpline: a.helpline === true,
    remember: list(a.remember, 2, 120),
  };
}

export async function chat(req, env, user) {
  const body = await req.json().catch(() => null);
  const messages = (Array.isArray(body?.messages) ? body.messages : [])
    .slice(-12)
    .filter((m) => (m?.role === 'user' || m?.role === 'assistant') && m.content)
    // An old empty "🎶" reply would teach the model to answer with just that.
    .filter((m) => !(m.role === 'assistant' && String(m.content).trim() === '🎶'))
    .map((m) => ({ role: m.role, content: clip(m.content, 1000) }));
  if (!messages.length || messages.at(-1).role !== 'user') return json({ error: 'bad_body' }, 400);

  if (!(await spend(env, user, 'chats', Number(env.AI_DAILY_LIMIT) || 100))) {
    return json({ error: 'ai_limit' }, 429);
  }
  const answer = await complete(env, [{ role: 'system', content: systemPrompt(body.context) }, ...messages], 900,
    (a) => replyOf(a) !== '' || (a.play && typeof a.play === 'object' && a.play.title));
  if (!answer) {
    await refund(env, user, 'chats');
    return json({ error: 'ai_down' }, 503);
  }
  return json(cleanAnswer(answer));
}

/** Moods for up to 30 songs: from the shared cache, the rest asked once. */
export async function tags(req, env, user) {
  const body = await req.json().catch(() => null);
  const songs = (Array.isArray(body?.songs) ? body.songs : [])
    .map((s) => ({ key: clip(s?.key, 200), title: clip(s?.title, 100), artist: clip(s?.artist, 100), album: clip(s?.album, 100) }))
    .filter((s) => s.key && s.title)
    .slice(0, 30);
  if (!songs.length) return json({ tags: {} });

  const keys = [...new Set(songs.map((s) => s.key))];
  const { results } = await env.DB.prepare(
    `SELECT key, moods FROM song_moods WHERE key IN (${keys.map(() => '?').join(',')})`).bind(...keys).all();
  const out = {};
  const known = new Set();
  for (const r of results) {
    known.add(r.key);
    if (r.moods) out[r.key] = r.moods.split(',');
  }
  const missing = songs.filter((s, i) => !known.has(s.key) && songs.findIndex((x) => x.key === s.key) === i);
  if (!missing.length || !(await spend(env, user, 'tags', Number(env.AI_TAG_LIMIT) || 300))) {
    return json({ tags: out });
  }

  const answer = await complete(env, [
    { role: 'system', content: `You label songs with moods for a music app (mostly Indian listeners).
For each numbered song give 1 to 3 moods from: ${MOODS.join(', ')}. Use [] if you don't know the song.
Answer ONLY with JSON: {"tags": {"0": ["sad", "calm"], "1": []}}` },
    { role: 'user', content: missing.map((s, i) =>
      `${i}. ${s.title} — ${s.artist}${s.album ? ` (album: ${s.album})` : ''}`).join('\n') },
  ], 600);
  if (!answer || typeof answer.tags !== 'object') {
    await refund(env, user, 'tags');
    return json({ tags: out });
  }
  const writes = [];
  missing.forEach((s, i) => {
    const moods = list(answer.tags[i] ?? answer.tags[String(i)], 3, 20)
      .map((x) => x.toLowerCase()).filter((x) => MOODS.includes(x));
    if (moods.length) out[s.key] = moods;
    // An unknown song is stored empty, so nobody asks for it again.
    writes.push(env.DB.prepare(
      'INSERT OR REPLACE INTO song_moods (key, moods, at) VALUES (?, ?, ?)').bind(s.key, moods.join(','), Date.now()));
  });
  await env.DB.batch(writes);
  return json({ tags: out });
}

/** "Report this reply": kept for the owner (admin page). */
export async function report(req, env, user) {
  const body = await req.json().catch(() => null);
  if (!body?.reply) return json({ error: 'bad_body' }, 400);
  await env.DB.batch([
    env.DB.prepare('INSERT INTO ai_reports (user_id, at, said, reply) VALUES (?, ?, ?, ?)')
      .bind(user.id, Date.now(), clip(body.said, 1000), clip(body.reply, 1500)),
    // Keep the newest 500.
    env.DB.prepare('DELETE FROM ai_reports WHERE id NOT IN (SELECT id FROM ai_reports ORDER BY id DESC LIMIT 500)'),
  ]);
  return json({ ok: true });
}

export async function listReports(env) {
  const { results } = await env.DB.prepare(
    `SELECT r.at, r.said, r.reply, u.email FROM ai_reports r LEFT JOIN users u ON u.id = r.user_id
     ORDER BY r.id DESC LIMIT 50`).all();
  return json({ reports: results });
}
