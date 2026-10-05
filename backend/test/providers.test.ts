import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import app from "../src/index";
import { enabledSources, PROVIDERS, SOURCES, streamable } from "../src/providers";
import { rank, resolveOne, search } from "../src/resolver";
import { archive, audius, jamendo, jiosaavn, youtube } from "../src/sources";
import { trackSchema } from "../src/track";
import jamendoSearch from "./fixtures/jamendo_search.json";
import jamendoTrack from "./fixtures/jamendo_track.json";
import { calledUrls, fixtures, json, mockFetch } from "./helpers";

// Tests flip registry fields the way a later phase will; put every provider back afterwards.
const original = SOURCES.map((s) => ({ ...PROVIDERS[s] }));
afterEach(() => SOURCES.forEach((s, i) => Object.assign(PROVIDERS[s], original[i])));

const LEGACY = ["audius", "jamendo", "archive"] as const;
const AUTH = { Authorization: "Bearer test-token" };
const hosts = (spy: ReturnType<typeof mockFetch>) => new Set(calledUrls(spy).map((u) => u.host));
const jamendoApi = (url: URL) => (url.host === "api.jamendo.com" ? json(url.searchParams.has("id") ? jamendoTrack : jamendoSearch) : undefined);

describe("provider registry", () => {
	it("lists each provider once, in query order, with the weights search has always used", () => {
		expect(SOURCES).toEqual(["jiosaavn", "audius", "jamendo", "archive", "youtube"]);
		expect(PROVIDERS).toMatchObject({
			jiosaavn: { name: "JioSaavn", enabled: true, kind: "audio", weight: 0.95, playback: "embed" },
			audius: { name: "Audius", enabled: true, kind: "audio", weight: 1, playback: "native" },
			jamendo: { name: "Jamendo", enabled: true, kind: "audio", weight: 0.95, playback: "native" },
			archive: { name: "Internet Archive", enabled: true, kind: "audio", weight: 0.7, playback: "native" },
			youtube: { name: "YouTube", enabled: true, kind: "video", weight: 0.9, playback: "embed" },
		});
	});

	it("wires every provider to its adapter", () => {
		expect(SOURCES.map((s) => PROVIDERS[s].adapter)).toEqual([jiosaavn, audius, jamendo, archive, youtube]);
	});

	it("has YouTube as its only video provider: an embed source that links out instead of streaming", () => {
		expect(enabledSources("audio")).toEqual(["jiosaavn", "audius", "jamendo", "archive"]);
		expect(enabledSources("video")).toEqual(["youtube"]);
		expect(PROVIDERS.youtube.deepLink?.("dQw4w9WgXcQ")).toBe("https://www.youtube.com/watch?v=dQw4w9WgXcQ");
		for (const s of LEGACY) expect(PROVIDERS[s].deepLink).toBeUndefined();
	});

	it("has JioSaavn as an audio provider that plays only in JioSaavn, so its links ride on each track", () => {
		expect(PROVIDERS.jiosaavn).toMatchObject({ kind: "audio", playback: "embed" });
		expect(PROVIDERS.jiosaavn.deepLink).toBeUndefined(); // song pages can't be built from an id
	});

	it("is the Track schema's list of sources", () => {
		const valid = (source: string) => trackSchema.safeParse({ source, sourceId: "x", title: "T", artist: "A", playable: true }).success;
		for (const s of SOURCES) expect(valid(s), s).toBe(true);
		expect(valid("spotify")).toBe(false);
		expect(valid("local")).toBe(false); // target providers join the registry when they are implemented
	});
});

describe("enabled flag", () => {
	it("keeps search from querying a disabled provider", async () => {
		PROVIDERS.audius.enabled = false;
		PROVIDERS.archive.enabled = false;
		expect(enabledSources()).toEqual(["jiosaavn", "jamendo", "youtube"]);

		const spy = mockFetch(fixtures);
		const { music } = await search(env, "lofi type beat", 10);
		expect(hosts(spy)).toEqual(new Set(["www.jiosaavn.com", "api.jamendo.com", "www.googleapis.com"]));
		expect(music.some((r) => r.source === "audius")).toBe(false);
	});

	it("keeps search from querying a disabled video provider", async () => {
		PROVIDERS.youtube.enabled = false;
		const spy = mockFetch(fixtures);
		const { videos, videoError } = await search(env, "blinding lights the weeknd", 10);
		expect(hosts(spy)).not.toContain("www.googleapis.com");
		expect({ videos, videoError }).toEqual({ videos: [], videoError: null }); // switched off, not failed
	});

	it("never serves answers cached under a different set of enabled providers", async () => {
		mockFetch(fixtures);
		const before = await search(env, "lofi type beat", 10);
		expect(before.music.some((r) => r.source === "audius")).toBe(true);

		PROVIDERS.audius.enabled = false;
		const off = await search(env, "lofi type beat", 10);
		expect(off.cached).toBe(false);
		expect(off.music.some((r) => r.source === "audius")).toBe(false);

		PROVIDERS.audius.enabled = true;
		expect(await search(env, "lofi type beat", 10)).toEqual({ ...before, cached: true });
	});

	it("drops JioSaavn from search when disabled, never serving answers cached while it was on", async () => {
		const spy = mockFetch(fixtures);
		const on = await search(env, "blinding lights the weeknd", 10);
		expect(on.music.some((r) => r.source === "jiosaavn")).toBe(true);

		PROVIDERS.jiosaavn.enabled = false;
		spy.mockClear();
		const off = await search(env, "blinding lights the weeknd", 10);
		expect(off.cached).toBe(false);
		expect(hosts(spy)).not.toContain("www.jiosaavn.com");
		expect(off.music.some((r) => r.source === "jiosaavn")).toBe(false);
	});

	it("keeps JioSaavn out of import matching, whatever its weight: its rows can't play in JARX", async () => {
		PROVIDERS.jiosaavn.weight = 1;
		const spy = mockFetch(fixtures);
		await resolveOne(env, "blinding lights the weeknd", "The Weeknd");
		expect(hosts(spy)).toEqual(new Set(["api.audius.co", "api.jamendo.com"]));
	});

	it("keeps import matching from querying a disabled provider", async () => {
		PROVIDERS.jamendo.enabled = false;
		const spy = mockFetch(fixtures);
		expect(await resolveOne(env, "lofi type beat bsdu")).toMatchObject({ id: "audius:ng9rl" });
		expect(hosts(spy)).toEqual(new Set(["api.audius.co"]));
	});

	it("still accepts a disabled provider's tracks and resolves their streams", async () => {
		PROVIDERS.audius.enabled = false;
		expect(trackSchema.parse({ source: "audius", sourceId: "YmJWK", title: "T", artist: "A", playable: true }).id).toBe("audius:YmJWK");

		mockFetch(fixtures);
		const res = await app.request("/tracks/audius/YmJWK/stream", { headers: AUTH }, env);
		expect(res.status).toBe(200);
		expect(((await res.json()) as { url: string }).url).toMatch(/^https:\/\/.+\/tracks\/cidstream\//);
	});
});

describe("resolver reads the registry", () => {
	it("scores with the registry's weight", () => {
		const exact = trackSchema.parse({ source: "jamendo", sourceId: "1", title: "Blinding Lights", artist: "The Weeknd", playable: true });
		expect(rank("blinding lights the weeknd", [exact], 1)[0].score).toBe(0.95);
		PROVIDERS.jamendo.weight = 0.8;
		expect(rank("blinding lights the weeknd", [exact], 1)[0].score).toBe(0.8);
	});

	it("sorts a provider's results into music or videos by its kind", async () => {
		mockFetch(fixtures);
		const before = await search(env, "lofi", 10);
		expect(before.music.some((r) => r.source === "archive")).toBe(true);
		expect(before.videos.some((r) => r.source === "archive")).toBe(false);

		await env.jarx_db.exec("DELETE FROM search_cache");
		PROVIDERS.archive.kind = "video";
		const after = await search(env, "lofi", 10);
		expect(after.music.some((r) => r.source === "archive")).toBe(false);
		expect(after.videos.some((r) => r.source === "archive")).toBe(true);
	});

	it("matches imports only against audio providers whose weight can reach a confident match", async () => {
		let spy = mockFetch(fixtures);
		await resolveOne(env, "lofi type beat bsdu");
		expect(hosts(spy)).toEqual(new Set(["api.audius.co", "api.jamendo.com"])); // archive's 0.7 never reaches HIT_SCORE

		vi.restoreAllMocks();
		PROVIDERS.archive.weight = 1;
		spy = mockFetch(fixtures);
		await resolveOne(env, "lofi type beat bsdu");
		expect(hosts(spy)).toEqual(new Set(["api.audius.co", "api.jamendo.com", "archive.org"]));
	});
});

describe("playable follows the registry", () => {
	// Simulates what adding a legitimate stream source to a provider would change: its playback type.
	const goNative = () => (PROVIDERS.jiosaavn.playback = "native");

	it("is everything but embed, and false for names that aren't providers", () => {
		expect(SOURCES.filter((s) => streamable(s))).toEqual(["audius", "jamendo", "archive"]);
		for (const name of ["local", "spotify", "toString", "__proto__", ""]) expect(streamable(name), name).toBe(false);
	});

	it("decides search results, whatever the adapter said, and a change skips the old cached answer", async () => {
		mockFetch(fixtures);
		const before = await search(env, "blinding lights the weeknd", 10);
		expect(before.music.filter((r) => r.source === "jiosaavn").every((r) => !r.playable)).toBe(true);

		goNative();
		const after = await search(env, "blinding lights the weeknd", 10);
		expect(after.cached).toBe(false);
		const saavn = after.music.filter((r) => r.source === "jiosaavn");
		expect(saavn.length).toBeGreaterThan(0);
		expect(saavn.every((r) => r.playable)).toBe(true);
	});

	it("decides stored tracks as they are read, in favorites, playlists and history", async () => {
		const call = async (method: string, path: string, body?: unknown) => {
			const res = await app.request(path, { method, headers: { ...AUTH, "content-type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) }, env);
			return (await res.json()) as any;
		};
		const saavn = { source: "jiosaavn", sourceId: "fW-Mxsnu", title: "Blinding Lights", artist: "The Weeknd", playable: false };
		const legacy = { source: "audius", sourceId: "a", title: "A", artist: "B", playable: true };
		await call("POST", "/favorites", { track: saavn });
		const { id } = await call("POST", "/playlists", { name: "P" });
		await call("POST", `/playlists/${id}/tracks`, { tracks: [saavn, legacy] });
		await call("POST", "/recently-played", { track: saavn });
		const read = async () =>
			[
				...(await call("GET", "/favorites")).items.map((i: any) => i.track),
				...(await call("GET", `/playlists/${id}`)).tracks.map((t: any) => t.track),
				...(await call("GET", "/recently-played")).items.map((i: any) => i.track),
			].map((t) => `${t.id}=${t.playable}`);

		expect(await read()).toEqual(["jiosaavn:fW-Mxsnu=false", "jiosaavn:fW-Mxsnu=false", "audius:a=true", "jiosaavn:fW-Mxsnu=false"]);
		goNative();
		expect(await read()).toEqual(["jiosaavn:fW-Mxsnu=true", "jiosaavn:fW-Mxsnu=true", "audius:a=true", "jiosaavn:fW-Mxsnu=true"]);
	});

	it("reads a stored track whose provider has left the registry as not playable", async () => {
		const gone = { id: "gone:1", source: "gone", sourceId: "1", title: "T", artist: "A", playable: true };
		await env.jarx_db.prepare("INSERT INTO favorite (track_key, track_json, added_at) VALUES (?, ?, 1)").bind(gone.id, JSON.stringify(gone)).run();
		const res = await app.request("/favorites", { headers: AUTH }, env);
		expect(((await res.json()) as any).items[0].track).toMatchObject({ id: "gone:1", playable: false });
	});
});

describe("legacy providers through the registry", () => {
	it.each(LEGACY)("%s still searches", async (s) => {
		mockFetch(jamendoApi, fixtures);
		const tracks = await PROVIDERS[s].adapter.search("lofi", 5, env, AbortSignal.timeout(2500));
		expect(tracks.length).toBeGreaterThan(0);
		expect(tracks.every((t) => t.source === s && t.playable && t.streamUrl)).toBe(true);
	});

	it("still resolves native streams, while YouTube still answers 422 without a request", async () => {
		const spy = mockFetch(jamendoApi, fixtures);
		const get = (path: string) => app.request(path, { headers: AUTH }, env);
		for (const path of ["/tracks/audius/YmJWK/stream", "/tracks/jamendo/1545361/stream", "/tracks/archive/item/a.mp3/stream"]) {
			expect((await get(path)).status, path).toBe(200);
		}

		const yt = await get("/tracks/youtube/dQw4w9WgXcQ/stream");
		expect(yt.status).toBe(422);
		expect(await yt.json()).toEqual({
			error: {
				code: "not_playable",
				message: "YouTube tracks are metadata-only; open the deep link",
				details: { deepLink: "https://www.youtube.com/watch?v=dQw4w9WgXcQ" },
			},
		});
		expect(hosts(spy)).not.toContain("www.googleapis.com");
	});

	it("answers 422 for a JioSaavn stream without asking JioSaavn: there is no stream to give", async () => {
		const spy = mockFetch(fixtures);
		const res = await app.request("/tracks/jiosaavn/fW-Mxsnu/stream", { headers: AUTH }, env);
		expect(res.status).toBe(422);
		expect(await res.json()).toEqual({ error: { code: "not_playable", message: "JioSaavn tracks are metadata-only; open the deep link" } });
		expect(spy).not.toHaveBeenCalled();
	});
});
