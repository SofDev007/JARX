import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import app from "../src/index";
import { calledUrls, fixtures, json, mockFetch } from "./helpers";

const AUTH = { Authorization: "Bearer test-token" };

async function api(method: string, path: string, body?: unknown, headers: Record<string, string> = AUTH) {
	const init: RequestInit = { method, headers: { ...headers } };
	if (typeof body === "string") init.body = body;
	else if (body !== undefined) {
		init.body = JSON.stringify(body);
		(init.headers as Record<string, string>)["content-type"] = "application/json";
	}
	const res = await app.request(path, init, env);
	return { status: res.status, headers: res.headers, body: res.status === 204 ? null : ((await res.json()) as any) };
}

const t = (n: number) => ({ source: "audius", sourceId: `t${n}`, title: `Track ${n}`, artist: "Artist", playable: true });
const ids = (detail: any) => detail.tracks.map((x: any) => x.track.id);
const positions = (detail: any) => detail.tracks.map((x: any) => x.position);

describe("auth", () => {
	it("leaves GET /health public", async () => {
		expect(await api("GET", "/health", undefined, {})).toMatchObject({ status: 200, body: { status: "ok" } });
	});

	it.each([
		["no header", {}],
		["wrong token", { Authorization: "Bearer nope" }],
		["token as prefix", { Authorization: "Bearer test-token-extra" }],
		["wrong scheme", { Authorization: "Basic test-token" }],
	])("rejects %s with 401", async (_, headers) => {
		const res = await api("GET", "/playlists", undefined, headers);
		expect(res.status).toBe(401);
		expect(res.body).toEqual({ error: { code: "unauthorized", message: "Missing or invalid bearer token" } });
		expect(res.headers.get("WWW-Authenticate")).toBe("Bearer");
	});

	it("protects every other route, including unknown ones and non-GET /health", async () => {
		for (const [method, path] of [
			["GET", "/search?q=x"],
			["GET", "/tracks/audius/x/stream"],
			["POST", "/playlists"],
			["GET", "/favorites"],
			["POST", "/recently-played"],
			["POST", "/import/playlist"],
			["GET", "/nope"],
			["POST", "/health"],
		]) {
			expect((await api(method, path, undefined, {})).status, `${method} ${path}`).toBe(401);
		}
	});

	it("fails closed when JARX_TOKEN is not configured", async () => {
		const res = await app.request("/playlists", { headers: { Authorization: "Bearer " } }, { ...env, JARX_TOKEN: "" });
		expect(res.status).toBe(401);
	});

	it("returns JSON 404s for unknown routes once authenticated", async () => {
		expect(await api("GET", "/nope")).toMatchObject({ status: 404, body: { error: { code: "not_found" } } });
	});
});

describe("validation and errors", () => {
	it("rejects bad query params with details", async () => {
		const res = await api("GET", "/search?limit=500");
		expect(res.status).toBe(400);
		expect(res.body.error.code).toBe("invalid_request");
		expect(res.body.error.details.map((d: any) => d.path).sort()).toEqual(["limit", "q"]);
	});

	it("rejects non-JSON bodies", async () => {
		expect(await api("POST", "/playlists", "{not json")).toMatchObject({ status: 400, body: { error: { code: "invalid_json" } } });
	});

	it("rejects invalid tracks, pointing at the field", async () => {
		const { body } = await api("POST", "/playlists", { name: "P" });
		const res = await api("POST", `/playlists/${body.id}/tracks`, { tracks: [{ ...t(1), source: "spotify" }] });
		expect(res.status).toBe(400);
		expect(res.body.error.details[0].path).toBe("tracks.0.source");
	});
});

describe("GET /search", () => {
	it("returns ranked results", async () => {
		mockFetch(fixtures);
		const res = await api("GET", "/search?q=lofi%20type%20beat&limit=5");
		expect(res.status).toBe(200);
		expect(res.body).toMatchObject({ query: "lofi type beat", cached: false });
		expect(res.body.results[0]).toMatchObject({ id: "audius:ng9rl", source: "audius", playable: true, mbid: null });
	});
});

describe("GET /tracks/:source/:id/stream", () => {
	it("resolves a fresh Audius URL", async () => {
		mockFetch(fixtures);
		const res = await api("GET", "/tracks/audius/YmJWK/stream");
		expect(res.status).toBe(200);
		expect(res.body.url).toMatch(/^https:\/\/.+\/tracks\/cidstream\//);
	});

	it("accepts archive ids containing slashes", async () => {
		const res = await api("GET", "/tracks/archive/item/dir/My%20Song.mp3/stream");
		expect(res.body).toEqual({ url: "https://archive.org/download/item/dir/My%20Song.mp3" });
	});

	it("refuses YouTube with the deep link instead", async () => {
		const res = await api("GET", "/tracks/youtube/dQw4w9WgXcQ/stream");
		expect(res.status).toBe(422);
		expect(res.body.error).toMatchObject({ code: "not_playable", details: { deepLink: "https://www.youtube.com/watch?v=dQw4w9WgXcQ" } });
	});

	it("maps upstream answers: unknown source 400, missing track 404, outage 502", async () => {
		expect((await api("GET", "/tracks/spotify/x/stream")).status).toBe(400);
		mockFetch(() => json({ code: 404, error: "track not found" }, 404));
		expect(await api("GET", "/tracks/audius/95wro/stream")).toMatchObject({ status: 404, body: { error: { code: "not_found" } } });
		expect((await api("GET", "/tracks/jamendo/not-a-number/stream")).status).toBe(404);
	});

	it("returns 502 when every Audius host is down", async () => {
		mockFetch(() => json({}, 500));
		expect(await api("GET", "/tracks/audius/YmJWK/stream")).toMatchObject({ status: 502, body: { error: { code: "upstream_error" } } });
	});
});

describe("playlists", () => {
	it("create → add → reorder → remove → rename → delete", async () => {
		const created = await api("POST", "/playlists", { name: "  Focus  " });
		expect(created.status).toBe(201);
		expect(created.body).toMatchObject({ name: "Focus", tracks: [] });
		const id = created.body.id;

		let res = await api("POST", `/playlists/${id}/tracks`, { tracks: [t(1), t(2), t(3)] });
		expect(res.status).toBe(201);
		expect(ids(res.body)).toEqual(["audius:t1", "audius:t2", "audius:t3"]);
		expect(positions(res.body)).toEqual([0, 1, 2]);
		expect(res.body.tracks[0].track).toEqual({
			id: "audius:t1",
			source: "audius",
			sourceId: "t1",
			title: "Track 1",
			artist: "Artist",
			album: null,
			artworkUrl: null,
			durationMs: null,
			streamUrl: null,
			mbid: null,
			playable: true,
			deepLink: null,
		});

		res = await api("POST", `/playlists/${id}/reorder`, { from: 0, to: 2 });
		expect(ids(res.body)).toEqual(["audius:t2", "audius:t3", "audius:t1"]);
		res = await api("POST", `/playlists/${id}/reorder`, { from: 2, to: 0 });
		expect(ids(res.body)).toEqual(["audius:t1", "audius:t2", "audius:t3"]);
		res = await api("POST", `/playlists/${id}/reorder`, { from: 1, to: 1 });
		expect(ids(res.body)).toEqual(["audius:t1", "audius:t2", "audius:t3"]);

		res = await api("DELETE", `/playlists/${id}/tracks/1`);
		expect(ids(res.body)).toEqual(["audius:t1", "audius:t3"]);
		expect(positions(res.body)).toEqual([0, 1]);

		res = await api("POST", `/playlists/${id}/tracks`, { tracks: [t(4)] });
		expect(ids(res.body)).toEqual(["audius:t1", "audius:t3", "audius:t4"]);
		expect(positions(res.body)).toEqual([0, 1, 2]);

		res = await api("PATCH", `/playlists/${id}`, { name: "Deep Focus" });
		expect(res.body.name).toBe("Deep Focus");

		const list = await api("GET", "/playlists");
		expect(list.body.playlists).toEqual([expect.objectContaining({ id, name: "Deep Focus", trackCount: 3 })]);

		expect((await api("DELETE", `/playlists/${id}`)).status).toBe(204);
		expect((await api("GET", `/playlists/${id}`)).status).toBe(404);
		const orphans = await env.jarx_db.prepare("SELECT COUNT(*) AS n FROM playlist_track").first<number>("n");
		expect(orphans).toBe(0); // ON DELETE CASCADE
	});

	it("derives track ids from source + sourceId, ignoring a client-supplied id", async () => {
		const { body } = await api("POST", "/playlists", { name: "P" });
		const res = await api("POST", `/playlists/${body.id}/tracks`, { tracks: [{ ...t(1), id: "forged" }] });
		expect(ids(res.body)).toEqual(["audius:t1"]);
	});

	it("404s on unknown playlists and positions, 400s on out-of-range moves", async () => {
		expect((await api("GET", "/playlists/missing")).status).toBe(404);
		expect((await api("POST", "/playlists/missing/tracks", { tracks: [t(1)] })).status).toBe(404);
		expect((await api("PATCH", "/playlists/missing", { name: "x" })).status).toBe(404);
		expect((await api("DELETE", "/playlists/missing")).status).toBe(404);

		const { body } = await api("POST", "/playlists", { name: "P" });
		await api("POST", `/playlists/${body.id}/tracks`, { tracks: [t(1), t(2)] });
		expect((await api("DELETE", `/playlists/${body.id}/tracks/5`)).status).toBe(404);
		expect((await api("POST", `/playlists/${body.id}/reorder`, { from: 0, to: 2 })).status).toBe(400);
		expect((await api("POST", `/playlists/${body.id}/reorder`, { from: -1, to: 0 })).status).toBe(400);
		expect((await api("POST", "/playlists", { name: "   " })).status).toBe(400);
	});
});

describe("favorites", () => {
	it("adds (idempotently), lists newest first and deletes by track id", async () => {
		const archiveTrack = { source: "archive", sourceId: "item/file name.mp3", title: "A", artist: "B", playable: true };
		expect((await api("POST", "/favorites", { track: t(1) })).status).toBe(201);
		await api("POST", "/favorites", { track: archiveTrack });
		await api("POST", "/favorites", { track: { ...t(1), title: "Renamed" } });

		let res = await api("GET", "/favorites");
		expect(res.body.items.map((i: any) => i.track.id).sort()).toEqual(["archive:item/file name.mp3", "audius:t1"]);
		expect(res.body.items.find((i: any) => i.track.id === "audius:t1").track.title).toBe("Renamed");

		expect((await api("DELETE", `/favorites/${encodeURIComponent("archive:item/file name.mp3")}`)).status).toBe(204);
		expect((await api("DELETE", "/favorites/audius:t1")).status).toBe(204);
		expect((await api("DELETE", "/favorites/audius:t1")).status).toBe(404);
		res = await api("GET", "/favorites");
		expect(res.body.items).toEqual([]);
	});
});

describe("recently played", () => {
	it("returns newest first and keeps only the last 200", async () => {
		const db = env.jarx_db;
		const insert = db.prepare("INSERT INTO recently_played (track_json, played_at) VALUES (?, ?)");
		await db.batch(Array.from({ length: 205 }, (_, i) => insert.bind(JSON.stringify({ ...t(i), id: `audius:t${i}` }), 1000 + i)));

		const posted = await api("POST", "/recently-played", { track: t(999) });
		expect(posted.status).toBe(201);

		expect(await db.prepare("SELECT COUNT(*) AS n FROM recently_played").first<number>("n")).toBe(200);
		const res = await api("GET", "/recently-played?limit=3");
		expect(res.body.items.map((i: any) => i.track.id)).toEqual(["audius:t999", "audius:t204", "audius:t203"]);
		expect((await api("GET", "/recently-played?limit=201")).status).toBe(400);
	});
});

describe("POST /import/playlist", () => {
	it("imports text lines: matches go in playable, misses become YouTube-search placeholders", async () => {
		const spy = mockFetch(fixtures);
		const text = ["kirbytape mix vol. 13 - lofi house edition - omgkirby", "Blinding Lights - The Weeknd", " - Nobody", ""].join("\n");
		const res = await api("POST", "/import/playlist?name=Road%20trip", text, { ...AUTH, "content-type": "text/plain" });

		expect(res.status).toBe(201);
		expect(res.body).toMatchObject({
			name: "Road trip",
			matched: 1,
			unmatched: [
				{ line: 2, title: "Blinding Lights", artist: "The Weeknd", reason: "no_match" },
				{ line: 3, title: " - Nobody", artist: "", reason: "malformed: missing title" },
			],
		});
		// Import never spends YouTube quota and skips archive (can't reach the match bar).
		expect(new Set(calledUrls(spy).map((u) => u.host))).toEqual(new Set(["api.audius.co", "api.jamendo.com"]));

		const detail = await api("GET", `/playlists/${res.body.playlistId}`);
		expect(detail.body.name).toBe("Road trip");
		expect(detail.body.tracks.map((x: any) => [x.position, x.track.id, x.track.playable])).toEqual([
			[0, "audius:YmJWK", true],
			[1, "youtube:search:Blinding Lights The Weeknd", false],
		]);
		expect(detail.body.tracks[1].track.deepLink).toBe("https://www.youtube.com/results?search_query=Blinding%20Lights%20The%20Weeknd");
	});

	it("imports Exportify CSV, keeping row metadata on placeholders", async () => {
		mockFetch(fixtures);
		const csv = [
			'"Track URI","Track Name","Artist URI(s)","Artist Name(s)","Album URI","Album Name","Track Duration (ms)"',
			'"spotify:track:1","lofi type beat","spotify:artist:1","[bsdu]","spotify:album:1","Beats","120000"',
			'"spotify:track:2","Blinding Lights","spotify:artist:2","The Weeknd","spotify:album:2","After Hours","200040"',
			'"spotify:track:3","Broken',
		].join("\n");
		const res = await api("POST", "/import/playlist", csv, { ...AUTH, "content-type": "text/csv" });
		expect(res.status).toBe(201);
		expect(res.body.name).toMatch(/^Imported \d{4}-\d{2}-\d{2}$/);
		expect(res.body.matched).toBe(1);
		expect(res.body.unmatched.map((u: any) => [u.line, u.reason])).toEqual([
			[3, "no_match"],
			[4, "malformed: unterminated quote"],
		]);
		const detail = await api("GET", `/playlists/${res.body.playlistId}`);
		expect(detail.body.tracks[1].track).toMatchObject({ source: "youtube", title: "Blinding Lights", album: "After Hours", durationMs: 200040, playable: false });
	});

	it("rejects bodies with no importable rows", async () => {
		const res = await api("POST", "/import/playlist", "\n - x\n", { ...AUTH, "content-type": "text/plain" });
		expect(res.status).toBe(400);
		expect(res.body.error.details.malformed).toHaveLength(1);
	});
});
