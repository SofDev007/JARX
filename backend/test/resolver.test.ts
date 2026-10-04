import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import { PROVIDERS } from "../src/providers";
import { gather, HIT_SCORE, MIN_SCORE, rank, resolveOne, search, similarity, TIMEOUT_MS } from "../src/resolver";
import type { Source, Track } from "../src/sources";
import audiusSearch from "./fixtures/audius_search.json";
import youtubeKeyInvalid from "./fixtures/youtube_error_key_invalid.json";
import youtubeSearch from "./fixtures/youtube_search.json";
import { calledUrls, fixtures, hang, json, mockFetch } from "./helpers";

const track = (source: Source, sourceId: string, title: string, artist: string): Track => ({
	id: `${source}:${sourceId}`,
	source,
	sourceId,
	title,
	artist,
	album: null,
	artworkUrl: null,
	durationMs: null,
	streamUrl: null,
	mbid: null,
	playable: source !== "youtube",
	deepLink: null,
});

describe("similarity", () => {
	it("is 1 for an exact title + artist query", () => {
		expect(similarity("Blinding Lights The Weeknd", "Blinding Lights", "The Weeknd")).toBe(1);
	});

	it("tolerates typos, case and punctuation", () => {
		expect(similarity("blindin lights weekend", "Blinding Lights", "The Weeknd")).toBeGreaterThan(HIT_SCORE);
		expect(similarity("lofi", "Lo-Fi Study Beats", "x")).toBeGreaterThan(HIT_SCORE);
		expect(similarity("beyonce halo", "Halo", "Beyoncé")).toBe(1);
	});

	it("is low for unrelated tracks", () => {
		expect(similarity("blinding lights the weeknd", "Stars In The Sky", "Lofi Beats")).toBeLessThan(MIN_SCORE);
	});

	it("prefers tighter matches", () => {
		expect(similarity("lofi", "Lofi", "A")).toBeGreaterThan(similarity("lofi", "Lofi Beats To Study And Relax To", "A"));
	});
});

describe("rank", () => {
	it("orders by similarity × source weight", () => {
		const results = rank(
			"blinding lights the weeknd",
			[
				track("archive", "a/live.mp3", "Blinding Lights Live", "The Weeknd"),
				track("audius", "edit", "Blinding Lights Extended Club Edit", "The Weeknd"),
				track("jamendo", "1", "Blinding Lights", "The Weeknd"),
			],
			10,
		);
		expect(results.map((r) => r.id)).toEqual(["jamendo:1", "audius:edit", "archive:a/live.mp3"]);
		expect(results[0].score).toBe(0.95); // perfect match × jamendo weight
		expect(results[2].score).toBeCloseTo(0.95 * 0.7, 2);
	});

	it("dedupes on normalized title + artist, keeping the best-scoring copy", () => {
		const results = rank(
			"blinding lights the weeknd",
			[
				track("archive", "a/1.mp3", "Blinding Lights", "The Weeknd"),
				track("audius", "x", "BLINDING LIGHTS!", "the weeknd"),
				track("jamendo", "1", "Blinding Lights", "The Weeknd"),
			],
			10,
		);
		expect(results).toHaveLength(1);
		expect(results[0]).toMatchObject({ id: "audius:x", score: 1 });
	});

	it("keeps the other copies as alternate sources instead of discarding them", () => {
		const [top] = rank(
			"blinding lights the weeknd",
			[
				track("archive", "a/1.mp3", "Blinding Lights", "The Weeknd"),
				track("audius", "x", "BLINDING LIGHTS!", "the weeknd"),
				track("jamendo", "1", "Blinding Lights", "The Weeknd"),
			],
			10,
		);
		// The best copy leads and is also the flat Track; the rest follow in the order they were found.
		expect(top.sources.map((s) => `${s.provider}:${s.sourceId}`)).toEqual(["audius:x", "archive:a/1.mp3", "jamendo:1"]);
		expect(top.sources[0]).toMatchObject({ provider: top.source, sourceId: top.sourceId, playback: "native", playable: true });
	});

	it(`drops results scoring below ${MIN_SCORE}`, () => {
		const results = rank(
			"blinding lights the weeknd",
			[track("audius", "a", "Blinding Lights (Cover)", "Someone Else"), track("audius", "b", "Stars In The Sky", "Lofi Beats")],
			10,
		);
		expect(results).toEqual([]);
	});

	it("respects the limit", () => {
		const many = Array.from({ length: 10 }, (_, i) => track("audius", String(i), `Lofi ${i}`, "Artist"));
		expect(rank("lofi", many, 3)).toHaveLength(3);
	});
});

describe("gather", () => {
	it("keeps the other sources when one fails", async () => {
		mockFetch((url) => {
			if (url.host === "archive.org") throw new TypeError("Network connection lost.");
		}, fixtures);
		const tracks = await gather(env, "lofi", 5, ["audius", "archive"]);
		expect(tracks.map((t) => t.source)).toEqual(["audius", "audius"]);
	});

	it(`aborts a hanging source after ${TIMEOUT_MS}ms, in parallel with the others`, async () => {
		mockFetch((url, signal) => (url.host === "archive.org" || url.host === "api.jamendo.com" ? hang(signal) : undefined), fixtures);
		const started = Date.now();
		const tracks = await gather(env, "lofi", 5, ["audius", "jamendo", "archive"]);
		const elapsed = Date.now() - started;
		expect(tracks.map((t) => t.source)).toEqual(["audius", "audius"]);
		expect(elapsed).toBeGreaterThanOrEqual(TIMEOUT_MS - 50);
		expect(elapsed).toBeLessThan(2 * TIMEOUT_MS); // both hanging sources timed out concurrently
	});

	// Jamendo answers 200/"success" with zero results at random; the warning is the only
	// way a rising flake rate shows up in `wrangler tail`.
	it("warns when Jamendo comes back empty while another source had hits", async () => {
		const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
		mockFetch(fixtures); // the shared fixture answers Jamendo with an empty success body
		await gather(env, "lofi", 5, ["audius", "jamendo"]);
		expect(warn).toHaveBeenCalledWith(expect.stringContaining("jamendo returned 0 results"));
	});

	it("stays quiet when no source found anything", async () => {
		const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
		mockFetch(fixtures);
		await gather(env, "lofi", 5, ["jamendo"]);
		expect(warn).not.toHaveBeenCalledWith(expect.stringContaining("jamendo returned 0 results"));
	});
});

describe("cover/remix demotion", () => {
	const byId = (q: string, tracks: Track[]) => new Map(rank(q, tracks, 10).map((t) => [t.sourceId, t]));

	it("demotes covers and remixes the query did not ask for, below the hit bar", () => {
		const r = byId("blinding lights the weeknd", [
			track("audius", "cover", "The Weeknd Blinding Lights - [COVER]", "DJ-M"),
			track("audius", "remix", "The Weeknd - Blinding Lights (Soldat Remix)", "Soldat"),
			track("audius", "real", "Blinding Lights", "The Weeknd"),
		]);

		expect(r.get("real")!.score).toBeGreaterThanOrEqual(HIT_SCORE); // the real track is still a confident hit
		for (const id of ["cover", "remix"]) {
			expect(r.get(id)!.score).toBeLessThan(HIT_SCORE); // ...so on its own, /search falls back to YouTube
			expect(r.get(id)!.score).toBeGreaterThanOrEqual(MIN_SCORE); // ...but they stay in the results
		}
	});

	it("demotes on the artist field, where a clean title hides a tribute act", () => {
		const r = byId("blinding lights the weeknd", [
			track("audius", "tribute", "Blinding Lights", "Weeknd Tribute Band"),
			track("audius", "real", "Blinding Lights", "The Weeknd"),
		]);
		expect(r.get("tribute")?.score ?? 0).toBeLessThan(HIT_SCORE); // demoted, and here far enough to drop out
		expect(r.get("real")!.score).toBeGreaterThanOrEqual(HIT_SCORE);
	});

	it.each([
		["remix", "blinding lights soldat remix", "The Weeknd - Blinding Lights (Soldat Remix)", "Soldat"],
		["karaoke", "blinding lights karaoke", "Blinding Lights (Karaoke Version)", "SingAlong"],
		["instrumental", "blinding lights instrumental", "Blinding Lights - Instrumental", "The Weeknd"],
		["made famous by", "blinding lights made famous by the weeknd", "Blinding Lights", "Made Famous By The Weeknd"],
	])("keeps %s at full score when the query asks for it", (_label, query, title, artist) => {
		const [top] = rank(query, [track("audius", "x", title, artist)], 1);
		expect(top.score).toBeGreaterThanOrEqual(HIT_SCORE);
	});

	it("still demotes a marker the query did not ask for, even when it asks for another", () => {
		const r = byId("blinding lights remix", [
			track("audius", "remix", "Blinding Lights (Soldat Remix)", "Soldat"),
			track("audius", "karaoke", "Blinding Lights (Karaoke)", "SingAlong"),
		]);
		expect(r.get("karaoke")?.score ?? 0).toBeLessThan(r.get("remix")!.score);
	});

	it("does not fire on words that merely contain a marker", () => {
		for (const title of ["Discovery", "Undercover Martyn", "Flipper"]) {
			const r = byId(title, [track("audius", "x", title, "A")]);
			expect(r.get("x")!.score).toBeGreaterThanOrEqual(HIT_SCORE);
		}
	});
});

describe("search", () => {
	const youtubeApi = (url: URL) => (url.host === "www.googleapis.com" ? json(youtubeSearch) : undefined);
	// The envelope recorded live (bad key), carrying the reason Google documents for a spent quota.
	const quotaExceeded = {
		error: { ...youtubeKeyInvalid.error, code: 403, errors: [{ ...youtubeKeyInvalid.error.errors[0], reason: "quotaExceeded" }] },
	};
	const cacheRows = async () => (await env.jarx_db.prepare("SELECT COUNT(*) AS n FROM search_cache").first<number>("n")) ?? 0;

	it.each([
		["lofi type beat", true],
		["blinding lights the weeknd", false],
	])("queries YouTube alongside the music providers for %j (confident music hit: %s)", async (q, hit) => {
		const spy = mockFetch(youtubeApi, fixtures);
		const { music } = await search(env, q, 10);

		expect(music.some((m) => m.playable && m.score >= HIT_SCORE)).toBe(hit);
		const yt = calledUrls(spy).filter((u) => u.host === "www.googleapis.com");
		expect(yt).toHaveLength(1);
		expect(yt[0].searchParams.get("type")).toBe("video");
		expect(yt[0].searchParams.get("videoCategoryId")).toBe("10");
	});

	it("keeps videos out of music: YouTube results land only in videos, as non-playable embed sources", async () => {
		mockFetch(youtubeApi, fixtures);
		const { music, videos, videoError } = await search(env, "blinding lights the weeknd", 10);

		expect(videoError).toBeNull();
		expect(videos.length).toBeGreaterThan(0);
		for (const v of videos) {
			expect(PROVIDERS[v.source].kind).toBe("video");
			expect(v).toMatchObject({ source: "youtube", playable: false, streamUrl: null, deepLink: `https://www.youtube.com/watch?v=${v.sourceId}` });
			expect(v.sources.every((s) => s.playback === "embed" && !s.playable)).toBe(true);
		}
		for (const m of music) expect(PROVIDERS[m.source].kind).toBe("audio");
	});

	it("gives each video its id, title, channel, thumbnail and watch link", async () => {
		mockFetch(youtubeApi, fixtures);
		const { videos } = await search(env, "blinding lights the weeknd", 10);
		expect(videos.find((v) => v.sourceId === "4NRXx6U8ABQ")).toMatchObject({
			id: "youtube:4NRXx6U8ABQ",
			title: expect.stringContaining("Blinding Lights"),
			artist: "TheWeekndVEVO",
			artworkUrl: expect.stringMatching(/^https:\/\/i\.ytimg\.com\//),
			deepLink: "https://www.youtube.com/watch?v=4NRXx6U8ABQ",
		});
	});

	it("still answers with music when YouTube's quota is spent, says so, and caches nothing", async () => {
		mockFetch((url) => (url.host === "www.googleapis.com" ? json(quotaExceeded, 403) : undefined), fixtures);
		const spent = await search(env, "lofi type beat", 10);
		expect(spent.music[0]).toMatchObject({ id: "audius:ng9rl" });
		expect(spent).toMatchObject({ videos: [], videoError: "quota_exceeded", cached: false });
		expect(await cacheRows()).toBe(0); // so the videos come back once the quota resets

		vi.restoreAllMocks();
		mockFetch(youtubeApi, fixtures);
		expect(await search(env, "lofi type beat", 10)).toMatchObject({ videoError: null, cached: false });
	});

	it("reports any other YouTube failure as unavailable", async () => {
		mockFetch((url) => (url.host === "www.googleapis.com" ? json(youtubeKeyInvalid, 400) : undefined), fixtures);
		expect(await search(env, "lofi type beat", 10)).toMatchObject({ videos: [], videoError: "unavailable" });
		expect(await cacheRows()).toBe(0);
	});

	it("caches results in D1 for 24h, keyed on the normalized query", async () => {
		const spy = mockFetch(youtubeApi, fixtures);
		const first = await search(env, "lofi type beat", 10);
		const calls = spy.mock.calls.length;

		expect(await search(env, "  LOFI Type Beat! ", 10)).toEqual({ ...first, cached: true });
		expect(spy.mock.calls.length).toBe(calls);

		await env.jarx_db.prepare("UPDATE search_cache SET fetched_at = fetched_at - ?").bind(24 * 60 * 60 * 1000).run();
		expect((await search(env, "lofi type beat", 10)).cached).toBe(false);
	});

	it("does not cache an empty result", async () => {
		mockFetch(() => json({}, 503));
		expect(await search(env, "lofi", 10)).toMatchObject({ music: [], videos: [] });
		expect(await cacheRows()).toBe(0);
	});
});

describe("resolveOne (import)", () => {
	it("returns the best confident playable match without querying archive or YouTube", async () => {
		const spy = mockFetch(fixtures);
		expect(await resolveOne(env, "lofi type beat bsdu")).toMatchObject({ id: "audius:ng9rl" });
		expect(new Set(calledUrls(spy).map((u) => u.host))).toEqual(new Set(["api.audius.co", "api.jamendo.com"]));
	});

	it("returns a flat Track, so imports never store score or sources", async () => {
		mockFetch(fixtures);
		const t = (await resolveOne(env, "lofi type beat bsdu"))!;
		expect(Object.keys(t).sort()).toEqual(
			["album", "artist", "artworkUrl", "deepLink", "durationMs", "id", "mbid", "playable", "source", "sourceId", "streamUrl", "title"],
		);
	});

	it("returns null when nothing is a confident match", async () => {
		mockFetch(fixtures);
		expect(await resolveOne(env, "blinding lights the weeknd")).toBeNull();
	});

	it("rejects covers whose artist doesn't match the row's artist", async () => {
		// Seen live: "The Weeknd Blinding Lights - [COVER]" by DJ-M outscored everything for this row.
		const [, streamable] = audiusSearch.data;
		const as = (id: string, title: string, name: string) => ({ ...streamable, id, title, user: { ...streamable.user, name } });
		const respond = (...data: unknown[]) => (url: URL) => (url.host === "api.audius.co" ? json({ data }) : undefined);

		mockFetch(respond(as("cover", "The Weeknd Blinding Lights - [COVER]", "DJ-M"), as("orig", "Blinding Lights", "The Weeknd")), fixtures);
		expect(await resolveOne(env, "Blinding Lights The Weeknd", "The Weeknd")).toMatchObject({ id: "audius:orig" });

		vi.restoreAllMocks();
		mockFetch(respond(as("cover", "The Weeknd Blinding Lights - [COVER]", "DJ-M")), fixtures);
		expect(await resolveOne(env, "Blinding Lights The Weeknd", "The Weeknd")).toBeNull();
	});
});
