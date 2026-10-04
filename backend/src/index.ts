import { Hono, type Context } from "hono";
import type { ContentfulStatusCode } from "hono/utils/http-status";
import { z } from "zod";
import { parseImport, rowQuery } from "./importer";
import { PROVIDERS, SOURCES } from "./providers";
import { resolveOne, search, TIMEOUT_MS } from "./resolver";
import { trackSchema, type Track } from "./track";

type Env = { Bindings: CloudflareBindings };

export class ApiError extends Error {
	constructor(readonly status: ContentfulStatusCode, readonly code: string, message: string, readonly details?: unknown) {
		super(message);
	}
}

const notFound = (what: string) => new ApiError(404, "not_found", `${what} not found`);

function parse<T extends z.ZodType>(schema: T, data: unknown): z.output<T> {
	const r = schema.safeParse(data);
	if (!r.success) {
		const details = r.error.issues.map((i) => ({ path: i.path.join("."), message: i.message }));
		throw new ApiError(400, "invalid_request", "Request validation failed", details);
	}
	return r.data;
}

async function jsonBody(c: Context) {
	try {
		return await c.req.json();
	} catch {
		throw new ApiError(400, "invalid_json", "Request body must be valid JSON");
	}
}

// Compare SHA-256 digests so the comparison is constant-time and length-independent.
async function tokenMatches(given: string, expected: string): Promise<boolean> {
	const enc = new TextEncoder();
	const [a, b] = await Promise.all([given, expected].map((s) => crypto.subtle.digest("SHA-256", enc.encode(s))));
	return crypto.subtle.timingSafeEqual(a, b);
}

const app = new Hono<Env>();

app.onError((err, c) => {
	if (err instanceof ApiError) {
		return c.json({ error: { code: err.code, message: err.message, ...(err.details !== undefined && { details: err.details }) } }, err.status);
	}
	console.error(err);
	return c.json({ error: { code: "internal_error", message: "Internal server error" } }, 500);
});
app.notFound((c) => c.json({ error: { code: "not_found", message: "Route not found" } }, 404));

// Registered before the auth middleware, so it is the only public route.
app.get("/health", (c) => c.json({ status: "ok" }));

app.use("*", async (c, next) => {
	const header = c.req.header("Authorization") ?? "";
	const expected = c.env.JARX_TOKEN;
	// Fail closed if the secret isn't configured.
	if (!expected || !header.startsWith("Bearer ") || !(await tokenMatches(header.slice(7), expected))) {
		c.header("WWW-Authenticate", "Bearer");
		throw new ApiError(401, "unauthorized", "Missing or invalid bearer token");
	}
	await next();
});

// --- Search & streams -------------------------------------------------------
const searchQuery = z.object({
	q: z.string().trim().min(1).max(200),
	limit: z.coerce.number().int().min(1).max(50).default(20),
});

app.get("/search", async (c) => {
	const { q, limit } = parse(searchQuery, c.req.query());
	const r = await search(c.env, q, limit);
	// `results` (music, then videos) is for app builds that predate the split; drop it once none are left.
	return c.json({ query: q, ...r, results: [...r.music, ...r.videos] });
});

// :id{.+} because archive ids are "<identifier>/<file>". Disabled providers still resolve
// here, so tracks already in the library keep playing.
app.get("/tracks/:source/:id{.+}/stream", async (c) => {
	const source = parse(z.enum(SOURCES), c.req.param("source"));
	const id = c.req.param("id");
	const provider = PROVIDERS[source];
	// Embed sources (YouTube) are metadata only: never extract or proxy their audio.
	if (provider.playback === "embed") {
		// JioSaavn's song links can't be built from an id; its tracks carry their own deepLink.
		throw new ApiError(
			422,
			"not_playable",
			`${provider.name} tracks are metadata-only; open the deep link`,
			provider.deepLink && { deepLink: provider.deepLink(id) },
		);
	}
	let url: string | null;
	try {
		url = await provider.adapter.streamUrl(id, c.env, AbortSignal.timeout(2 * TIMEOUT_MS));
	} catch (e) {
		console.warn(`stream ${source} failed: ${String(e).replace(/(key|client_id)=[^&\s]+/g, "$1=***")}`);
		throw new ApiError(502, "upstream_error", `Could not resolve a stream from ${source}`);
	}
	if (!url) throw notFound("Track");
	return c.json({ url });
});

// --- Playlists --------------------------------------------------------------
const nameSchema = z.object({ name: z.string().trim().min(1).max(200) });
const tracksBody = z.object({ tracks: z.array(trackSchema).min(1).max(500) });
const moveBody = z.object({ from: z.number().int().min(0), to: z.number().int().min(0) });

type TrackRow = { position: number; addedAt: number; track_json: string };

async function playlistDetail(db: D1Database, id: string) {
	const [meta, rows] = await db.batch([
		db.prepare("SELECT id, name, created_at AS createdAt, updated_at AS updatedAt FROM playlist WHERE id = ?").bind(id),
		db.prepare("SELECT position, added_at AS addedAt, track_json FROM playlist_track WHERE playlist_id = ? ORDER BY position").bind(id),
	]);
	const playlist = meta.results[0];
	if (!playlist) throw notFound("Playlist");
	const tracks = (rows.results as TrackRow[]).map((r) => ({ position: r.position, addedAt: r.addedAt, track: JSON.parse(r.track_json) as Track }));
	return { ...playlist, tracks };
}

// Bumps updated_at; doubles as the existence check for track mutations.
async function touchPlaylist(db: D1Database, id: string, now = Date.now()) {
	const r = await db.prepare("UPDATE playlist SET updated_at = ? WHERE id = ?").bind(now, id).run();
	if (!r.meta.changes) throw notFound("Playlist");
}

// Appends in one statement: json_each yields (key = array index, value = track JSON).
const appendTracks = (db: D1Database, id: string, tracks: Track[], now: number) =>
	db
		.prepare(
			`INSERT INTO playlist_track (playlist_id, position, track_json, added_at)
			 SELECT ?1, (SELECT COALESCE(MAX(position) + 1, 0) FROM playlist_track WHERE playlist_id = ?1) + key, value, ?2
			 FROM json_each(?3)`,
		)
		.bind(id, now, JSON.stringify(tracks));

app.get("/playlists", async (c) => {
	const { results } = await c.env.jarx_db
		.prepare(
			`SELECT p.id, p.name, p.created_at AS createdAt, p.updated_at AS updatedAt,
			        (SELECT COUNT(*) FROM playlist_track t WHERE t.playlist_id = p.id) AS trackCount
			 FROM playlist p ORDER BY p.updated_at DESC`,
		)
		.all();
	return c.json({ playlists: results });
});

app.post("/playlists", async (c) => {
	const { name } = parse(nameSchema, await jsonBody(c));
	const id = crypto.randomUUID();
	const now = Date.now();
	await c.env.jarx_db.prepare("INSERT INTO playlist (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)").bind(id, name, now, now).run();
	return c.json({ id, name, createdAt: now, updatedAt: now, tracks: [] }, 201);
});

app.get("/playlists/:id", async (c) => c.json(await playlistDetail(c.env.jarx_db, c.req.param("id"))));

app.patch("/playlists/:id", async (c) => {
	const { name } = parse(nameSchema, await jsonBody(c));
	const db = c.env.jarx_db;
	const r = await db.prepare("UPDATE playlist SET name = ?, updated_at = ? WHERE id = ?").bind(name, Date.now(), c.req.param("id")).run();
	if (!r.meta.changes) throw notFound("Playlist");
	return c.json(await playlistDetail(db, c.req.param("id")));
});

app.delete("/playlists/:id", async (c) => {
	const r = await c.env.jarx_db.prepare("DELETE FROM playlist WHERE id = ?").bind(c.req.param("id")).run();
	if (!r.meta.changes) throw notFound("Playlist");
	return c.body(null, 204);
});

app.post("/playlists/:id/tracks", async (c) => {
	const { tracks } = parse(tracksBody, await jsonBody(c));
	const db = c.env.jarx_db;
	const id = c.req.param("id");
	const now = Date.now();
	await touchPlaylist(db, id, now);
	await appendTracks(db, id, tracks, now).run();
	return c.json(await playlistDetail(db, id), 201);
});

app.delete("/playlists/:id/tracks/:position", async (c) => {
	const position = parse(z.coerce.number().int().min(0), c.req.param("position"));
	const db = c.env.jarx_db;
	const id = c.req.param("id");
	await touchPlaylist(db, id);
	const [deleted] = await db.batch([
		db.prepare("DELETE FROM playlist_track WHERE playlist_id = ? AND position = ?").bind(id, position),
		db.prepare("UPDATE playlist_track SET position = position - 1 WHERE playlist_id = ? AND position > ?").bind(id, position),
	]);
	if (!deleted.meta.changes) throw notFound("Track position");
	return c.json(await playlistDetail(db, id));
});

// Move the track at `from` to `to`, shifting the tracks in between by one.
app.post("/playlists/:id/reorder", async (c) => {
	const { from, to } = parse(moveBody, await jsonBody(c));
	const db = c.env.jarx_db;
	const id = c.req.param("id");
	await touchPlaylist(db, id);
	const count = (await db.prepare("SELECT COUNT(*) AS n FROM playlist_track WHERE playlist_id = ?").bind(id).first<number>("n")) ?? 0;
	if (from >= count || to >= count) throw new ApiError(400, "invalid_request", `Positions must be below ${count}`);
	await db
		.prepare(
			`UPDATE playlist_track SET position = CASE WHEN position = ?2 THEN ?3 WHEN ?2 < ?3 THEN position - 1 ELSE position + 1 END
			 WHERE playlist_id = ?1 AND position BETWEEN min(?2, ?3) AND max(?2, ?3)`,
		)
		.bind(id, from, to)
		.run();
	return c.json(await playlistDetail(db, id));
});

// --- Favorites & recently played --------------------------------------------
const trackBody = z.object({ track: trackSchema });
const RECENT_KEEP = 200;

app.get("/favorites", async (c) => {
	const { results } = await c.env.jarx_db
		.prepare("SELECT track_json, added_at AS addedAt FROM favorite ORDER BY added_at DESC")
		.all<{ track_json: string; addedAt: number }>();
	return c.json({ items: results.map((r) => ({ track: JSON.parse(r.track_json) as Track, addedAt: r.addedAt })) });
});

app.post("/favorites", async (c) => {
	const { track } = parse(trackBody, await jsonBody(c));
	const addedAt = Date.now();
	// Re-favoriting refreshes the stored track but keeps the original added_at.
	await c.env.jarx_db
		.prepare(
			`INSERT INTO favorite (track_key, track_json, added_at) VALUES (?, ?, ?)
			 ON CONFLICT (track_key) DO UPDATE SET track_json = excluded.track_json`,
		)
		.bind(track.id, JSON.stringify(track), addedAt)
		.run();
	return c.json({ track }, 201);
});

// Key is Track.id, e.g. /favorites/audius:95wro or /favorites/archive:item/file.mp3
app.delete("/favorites/:key{.+}", async (c) => {
	const r = await c.env.jarx_db.prepare("DELETE FROM favorite WHERE track_key = ?").bind(c.req.param("key")).run();
	if (!r.meta.changes) throw notFound("Favorite");
	return c.body(null, 204);
});

app.get("/recently-played", async (c) => {
	const { limit } = parse(z.object({ limit: z.coerce.number().int().min(1).max(RECENT_KEEP).default(50) }), c.req.query());
	const { results } = await c.env.jarx_db
		.prepare("SELECT track_json, played_at AS playedAt FROM recently_played ORDER BY played_at DESC, rowid DESC LIMIT ?")
		.bind(limit)
		.all<{ track_json: string; playedAt: number }>();
	return c.json({ items: results.map((r) => ({ track: JSON.parse(r.track_json) as Track, playedAt: r.playedAt })) });
});

app.post("/recently-played", async (c) => {
	const { track } = parse(trackBody, await jsonBody(c));
	const db = c.env.jarx_db;
	const playedAt = Date.now();
	await db.batch([
		db.prepare("INSERT INTO recently_played (track_json, played_at) VALUES (?, ?)").bind(JSON.stringify(track), playedAt),
		db
			.prepare(
				`DELETE FROM recently_played WHERE rowid NOT IN
				 (SELECT rowid FROM recently_played ORDER BY played_at DESC, rowid DESC LIMIT ?)`,
			)
			.bind(RECENT_KEEP),
	]);
	return c.json({ track, playedAt }, 201);
});

// --- Import -----------------------------------------------------------------
const MAX_IMPORT_BYTES = 1_000_000;
const MAX_IMPORT_ROWS = 500;
const IMPORT_CONCURRENCY = 3; // 2 fetches per row; Workers allow 6 connections waiting on headers

app.post("/import/playlist", async (c) => {
	const { name, playlistId: into } = parse(
		z.object({
			name: z.string().trim().min(1).max(200).default(`Imported ${new Date().toISOString().slice(0, 10)}`),
			// Appends to an existing playlist instead, so a client can split a large import across
			// requests: each row costs ~2 subrequests and the Free plan allows 50 per request.
			playlistId: z.string().min(1).max(100).optional(),
		}),
		c.req.query(),
	);
	const text = await c.req.text();
	if (text.length > MAX_IMPORT_BYTES) throw new ApiError(413, "payload_too_large", `Import body must be under ${MAX_IMPORT_BYTES} bytes`);
	const { rows, malformed } = parseImport(text);
	if (!rows.length) throw new ApiError(400, "invalid_request", "No importable rows found", { malformed });
	if (rows.length > MAX_IMPORT_ROWS) throw new ApiError(400, "invalid_request", `At most ${MAX_IMPORT_ROWS} rows per import`);
	const target = into
		? await c.env.jarx_db.prepare("SELECT name FROM playlist WHERE id = ?").bind(into).first<{ name: string }>()
		: null;
	if (into && !target) throw notFound("Playlist");

	const tracks: Track[] = new Array(rows.length);
	const unmatched: { line: number; title: string; artist: string; reason: string }[] = [];
	let next = 0;
	const worker = async () => {
		while (next < rows.length) {
			const i = next++;
			const row = rows[i];
			const query = rowQuery(row);
			const match = await resolveOne(c.env, query, row.artist);
			if (match) tracks[i] = match;
			else {
				unmatched.push({ line: row.line, title: row.title, artist: row.artist, reason: "no_match" });
				// Stored as a non-playable placeholder that opens a YouTube search (costs no API quota).
				tracks[i] = parse(trackSchema, {
					source: "youtube",
					sourceId: `search:${query}`,
					title: row.title,
					artist: row.artist,
					album: row.album,
					durationMs: row.durationMs,
					playable: false,
					deepLink: `https://www.youtube.com/results?search_query=${encodeURIComponent(query)}`,
				});
			}
		}
	};
	await Promise.all(Array.from({ length: IMPORT_CONCURRENCY }, worker));

	const db = c.env.jarx_db;
	const playlistId = into ?? crypto.randomUUID();
	const now = Date.now();
	await db.batch([
		into
			? db.prepare("UPDATE playlist SET updated_at = ? WHERE id = ?").bind(now, playlistId)
			: db.prepare("INSERT INTO playlist (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)").bind(playlistId, name, now, now),
		appendTracks(db, playlistId, tracks, now),
	]);
	unmatched.push(...malformed.map((m) => ({ line: m.line, title: m.raw, artist: "", reason: `malformed: ${m.reason}` })));
	unmatched.sort((a, b) => a.line - b.line);
	return c.json({ playlistId, name: target?.name ?? name, matched: rows.length - unmatched.filter((u) => u.reason === "no_match").length, unmatched }, 201);
});

export default app;
