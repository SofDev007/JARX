import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import app from "../src/index";
import { enabledSources, PROVIDERS, SOURCES } from "../src/providers";
import { rank, resolveOne, search } from "../src/resolver";
import { archive, audius, jamendo, youtube } from "../src/sources";
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
		expect(SOURCES).toEqual(["audius", "jamendo", "archive", "youtube"]);
		expect(PROVIDERS).toMatchObject({
			audius: { name: "Audius", enabled: true, kind: "audio", weight: 1, playback: "native" },
			jamendo: { name: "Jamendo", enabled: true, kind: "audio", weight: 0.95, playback: "native" },
			archive: { name: "Internet Archive", enabled: true, kind: "audio", weight: 0.7, playback: "native" },
			youtube: { name: "YouTube", enabled: true, kind: "video", weight: 0.9, playback: "embed" },
		});
	});

	it("wires every provider to its adapter", () => {
		expect([PROVIDERS.audius.adapter, PROVIDERS.jamendo.adapter, PROVIDERS.archive.adapter, PROVIDERS.youtube.adapter]).toEqual([
			audius,
			jamendo,
			archive,
			youtube,
		]);
	});

	it("has YouTube as its only video provider: an embed source that links out instead of streaming", () => {
		expect(enabledSources("audio")).toEqual(["audius", "jamendo", "archive"]);
		expect(enabledSources("video")).toEqual(["youtube"]);
		expect(PROVIDERS.youtube.deepLink?.("dQw4w9WgXcQ")).toBe("https://www.youtube.com/watch?v=dQw4w9WgXcQ");
		for (const s of LEGACY) expect(PROVIDERS[s].deepLink).toBeUndefined();
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
		expect(enabledSources()).toEqual(["jamendo", "youtube"]);

		const spy = mockFetch(fixtures);
		const { results } = await search(env, "lofi type beat", 10);
		expect(hosts(spy)).toEqual(new Set(["api.jamendo.com", "www.googleapis.com"])); // no playable hit left, so YouTube was asked
		expect(results.some((r) => r.source === "audius")).toBe(false);
	});

	it("drops a disabled video provider from the fallback too", async () => {
		PROVIDERS.youtube.enabled = false;
		const spy = mockFetch(fixtures);
		await search(env, "blinding lights the weeknd", 10); // no confident playable match: normally asks YouTube
		expect(hosts(spy)).not.toContain("www.googleapis.com");
	});

	it("never serves answers cached under a different set of enabled providers", async () => {
		mockFetch(fixtures);
		const before = await search(env, "lofi type beat", 10);
		expect(before.results.some((r) => r.source === "audius")).toBe(true);

		PROVIDERS.audius.enabled = false;
		const off = await search(env, "lofi type beat", 10);
		expect(off.cached).toBe(false);
		expect(off.results.some((r) => r.source === "audius")).toBe(false);

		PROVIDERS.audius.enabled = true;
		expect(await search(env, "lofi type beat", 10)).toEqual({ results: before.results, cached: true });
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

	it("queries a provider up front or only as the fallback according to its kind", async () => {
		let spy = mockFetch(fixtures);
		await search(env, "lofi type beat", 10); // Audius has a confident hit, so no fallback runs
		expect(hosts(spy)).toContain("archive.org");

		vi.restoreAllMocks();
		await env.jarx_db.exec("DELETE FROM search_cache");
		PROVIDERS.archive.kind = "video";
		spy = mockFetch(fixtures);
		await search(env, "lofi type beat", 10);
		expect(hosts(spy)).not.toContain("archive.org");
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
});
