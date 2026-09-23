import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import { gather, HIT_SCORE, MIN_SCORE, rank, resolveOne, search, similarity, TIMEOUT_MS } from "../src/resolver";
import type { Source, Track } from "../src/sources";
import audiusSearch from "./fixtures/audius_search.json";
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

	it("keeps them at full score when the query asks for a remix", () => {
		const t = track("audius", "remix", "The Weeknd - Blinding Lights (Soldat Remix)", "Soldat");
		expect(byId("blinding lights soldat remix", [t]).get("remix")!.score).toBeGreaterThanOrEqual(HIT_SCORE);
	});

	it("does not fire on words that merely contain a marker", () => {
		for (const title of ["Discovery", "Undercover Martyn", "Flipper"]) {
			const r = byId(title, [track("audius", "x", title, "A")]);
			expect(r.get("x")!.score).toBeGreaterThanOrEqual(HIT_SCORE);
		}
	});
});

describe("search", () => {
	it("does not call YouTube when a playable result is a confident match", async () => {
		const spy = mockFetch(fixtures);
		const { results, cached } = await search(env, "lofi type beat", 10);
		expect(cached).toBe(false);
		expect(results[0]).toMatchObject({ id: "audius:ng9rl", playable: true });
		expect(results[0].score).toBeGreaterThanOrEqual(HIT_SCORE);
		expect(calledUrls(spy).map((u) => u.host)).not.toContain("www.googleapis.com");
	});

	it("falls back to YouTube (metadata only) when nothing playable is a confident match", async () => {
		const spy = mockFetch((url) => (url.host === "www.googleapis.com" ? json(youtubeSearch) : undefined), fixtures);
		const { results } = await search(env, "blinding lights the weeknd", 10);

		const yt = calledUrls(spy).filter((u) => u.host === "www.googleapis.com");
		expect(yt).toHaveLength(1);
		expect(yt[0].searchParams.get("type")).toBe("video");
		expect(yt[0].searchParams.get("videoCategoryId")).toBe("10");

		expect(results.length).toBeGreaterThan(0);
		for (const r of results.filter((r) => r.source === "youtube")) {
			expect(r).toMatchObject({ playable: false, streamUrl: null, deepLink: `https://www.youtube.com/watch?v=${r.sourceId}` });
		}
		expect(results.some((r) => r.source === "youtube")).toBe(true);
	});

	it("still answers when YouTube fails (e.g. quota exceeded)", async () => {
		mockFetch(
			(url) => (url.host === "www.googleapis.com" ? json({ error: { code: 403, errors: [{ reason: "quotaExceeded" }] } }, 403) : undefined),
			fixtures,
		);
		const { results } = await search(env, "blinding lights the weeknd", 10);
		expect(results.every((r) => r.source !== "youtube")).toBe(true);
	});

	it("caches results in D1 for 24h, keyed on the normalized query", async () => {
		const spy = mockFetch(fixtures);
		const first = await search(env, "lofi type beat", 10);
		const calls = spy.mock.calls.length;

		expect(await search(env, "  LOFI Type Beat! ", 10)).toEqual({ results: first.results, cached: true });
		expect(spy.mock.calls.length).toBe(calls);

		await env.jarx_db.prepare("UPDATE search_cache SET fetched_at = fetched_at - ?").bind(24 * 60 * 60 * 1000).run();
		expect((await search(env, "lofi type beat", 10)).cached).toBe(false);
	});

	it("does not cache an empty result", async () => {
		mockFetch(() => json({}, 503));
		expect((await search(env, "lofi", 10)).results).toEqual([]);
		const { n } = (await env.jarx_db.prepare("SELECT COUNT(*) AS n FROM search_cache").first<{ n: number }>())!;
		expect(n).toBe(0);
	});
});

describe("resolveOne (import)", () => {
	it("returns the best confident playable match without querying archive or YouTube", async () => {
		const spy = mockFetch(fixtures);
		expect(await resolveOne(env, "lofi type beat bsdu")).toMatchObject({ id: "audius:ng9rl" });
		expect(new Set(calledUrls(spy).map((u) => u.host))).toEqual(new Set(["api.audius.co", "api.jamendo.com"]));
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
