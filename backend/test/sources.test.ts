import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import { archive, audius, decodeEntities, HttpError, jamendo, jiosaavn, youtube } from "../src/sources";
import jamendoSearch from "./fixtures/jamendo_search.json";
import jamendoTrack from "./fixtures/jamendo_track.json";
import jiosaavnSearch from "./fixtures/jiosaavn_search.json";
import jiosaavnRaatBhar from "./fixtures/jiosaavn_search_raat_bhar.json";
import privateFiles from "./fixtures/archive_files_private.json";
import { calledUrls, fixtures, html, json, mockFetch } from "./helpers";

const signal = () => AbortSignal.timeout(2500);

const jamendoApi = (url: URL) => (url.host === "api.jamendo.com" ? json(url.searchParams.has("id") ? jamendoTrack : jamendoSearch) : undefined);

describe("audius", () => {
	it("maps search results and drops tracks that are not streamable", async () => {
		const spy = mockFetch(fixtures);
		const tracks = await audius.search("lofi", 3, env, signal());

		const url = calledUrls(spy)[0];
		expect(url.host).toBe("api.audius.co");
		expect(url.searchParams.get("app_name")).toBe("JARX");
		expect(url.searchParams.get("query")).toBe("lofi");

		// Fixture has 3 tracks; "95wro" belongs to a deactivated user (is_streamable: false).
		expect(tracks.map((t) => t.sourceId)).toEqual(["YmJWK", "ng9rl"]);
		expect(tracks[0]).toMatchObject({
			id: "audius:YmJWK",
			source: "audius",
			title: "kirbytape mix vol. 13 - lofi house edition",
			artist: "omgkirby",
			album: null,
			durationMs: 1_690_000,
			mbid: null,
			playable: true,
			deepLink: null,
		});
		expect(tracks[0].artworkUrl).toMatch(/^https:\/\/.+480x480\.jpg$/);
		expect(tracks[0].streamUrl).toMatch(/^https:\/\/.+\/tracks\/cidstream\//);
	});

	it("resolves a fresh stream URL", async () => {
		mockFetch(fixtures);
		expect(await audius.streamUrl("YmJWK", env, signal())).toMatch(/^https:\/\/.+\/tracks\/cidstream\/.+signature=/);
	});

	it("retries another host when the first one fails", async () => {
		const spy = mockFetch((url) => (url.host === "api.audius.co" ? json({ error: "down" }, 503) : undefined), (url) =>
			url.host === "discoveryprovider.audius.co" ? fixtures(new URL(url.pathname + url.search, "https://api.audius.co")) : undefined,
		);
		const tracks = await audius.search("lofi", 3, env, signal());
		expect(tracks).toHaveLength(2);
		expect(calledUrls(spy).map((u) => u.host)).toEqual(["api.audius.co", "discoveryprovider.audius.co"]);
	});

	it("retries another host on network errors too", async () => {
		const spy = mockFetch((url) => {
			if (url.host === "api.audius.co") throw new TypeError("Network connection lost.");
			return fixtures(new URL(url.pathname + url.search, "https://api.audius.co"));
		});
		expect(await audius.search("lofi", 3, env, signal())).toHaveLength(2);
		expect(spy).toHaveBeenCalledTimes(2);
	});

	it("treats a 404 as a real answer: no retry, null stream", async () => {
		// Recorded live: {"code":404,"error":"track not found"}
		const spy = mockFetch(() => json({ code: 404, error: "track not found" }, 404));
		expect(await audius.streamUrl("95wro", env, signal())).toBeNull();
		expect(spy).toHaveBeenCalledTimes(1);
	});

	it("throws when every host fails", async () => {
		mockFetch(() => json({}, 502));
		await expect(audius.search("lofi", 3, env, signal())).rejects.toBeInstanceOf(HttpError);
	});
});

describe("archive", () => {
	it("searches audio items and picks their public MP3 files", async () => {
		const spy = mockFetch(fixtures);
		const tracks = await archive.search("lofi", 20, env, signal());

		const search = calledUrls(spy).find((u) => u.pathname === "/advancedsearch.php")!;
		expect(search.searchParams.get("q")).toBe('(title:(lofi) OR creator:(lofi)) AND mediatype:audio AND format:"VBR MP3"');
		expect(search.searchParams.get("rows")).toBe("5");

		// 4 single-file items + 10 of the 16 files in "kalaido-hanging-lanterns_202101" (capped per item).
		expect(tracks).toHaveLength(14);
		const t = tracks.find((t) => t.sourceId.startsWith("LofiBeatsRadio2/"))!;
		expect(t).toMatchObject({
			source: "archive",
			artist: "Lofi Hip Hop Producer Andre Ramone",
			artworkUrl: "https://archive.org/services/img/LofiBeatsRadio2",
			playable: true,
			mbid: null,
		});
		expect(t.id).toBe(`archive:${t.sourceId}`);
		expect(t.streamUrl).toBe(`https://archive.org/download/LofiBeatsRadio2/${encodeURIComponent(t.sourceId.slice("LofiBeatsRadio2/".length))}`);
		expect(t.durationMs).toBeGreaterThan(0);
	});

	it("skips private files", async () => {
		mockFetch((url) =>
			url.pathname === "/advancedsearch.php"
				? json({ response: { docs: [{ identifier: "szrhome5czd2qdczbwrjuk3plbujbccczg1zpa8d", title: "Goodnight, Friend - Lofi Hiphop Mix" }] } })
				: json(privateFiles),
		);
		expect(await archive.search("lofi", 5, env, signal())).toEqual([]);
	});

	it("strips Lucene syntax from the query", async () => {
		const spy = mockFetch(fixtures);
		await archive.search('lofi" OR (x:*', 5, env, signal());
		expect(calledUrls(spy)[0].searchParams.get("q")).toContain("title:(lofi  OR  x)");
	});

	it("builds stable download URLs without a request", async () => {
		const spy = mockFetch();
		expect(await archive.streamUrl("item/dir/My Song #1.mp3", env, signal())).toBe("https://archive.org/download/item/dir/My%20Song%20%231.mp3");
		expect(await archive.streamUrl("no-file", env, signal())).toBeNull();
		expect(spy).not.toHaveBeenCalled();
	});
});

describe("jamendo", () => {
	it("fails (and so is skipped by the resolver) without a client id", async () => {
		await expect(jamendo.search("x", 5, { ...env, JAMENDO_CLIENT_ID: "" }, signal())).rejects.toThrow("JAMENDO_CLIENT_ID");
	});

	it("reports API errors returned with HTTP 200", async () => {
		mockFetch(() => json({ headers: { status: "failed", code: 5, error_message: "Your credential is not authorized.", warnings: "", results_count: 0 }, results: [] }));
		await expect(jamendo.search("x", 5, env, signal())).rejects.toThrow("jamendo error 5");
	});

	it("maps search results", async () => {
		const spy = mockFetch(jamendoApi);
		const tracks = await jamendo.search("lofi", 5, env, signal());

		const url = calledUrls(spy)[0];
		expect(url.host).toBe("api.jamendo.com");
		expect(url.searchParams.get("client_id")).toBe(env.JAMENDO_CLIENT_ID);
		expect(url.searchParams.get("search")).toBe("lofi");
		expect(url.searchParams.get("limit")).toBe("5");

		expect(tracks).toHaveLength(5);
		expect(tracks[0]).toMatchObject({
			id: "jamendo:1545361",
			source: "jamendo",
			sourceId: "1545361",
			title: "Master Beat inside Lofi",
			artist: "Lysergic Tempo",
			album: "Master Beat inside Lofi",
			durationMs: 264_000,
			mbid: null,
			playable: true,
			deepLink: null,
		});
		expect(tracks[0].streamUrl).toContain("storage.jamendo.com/?trackid=1545361");
		expect(tracks[0].artworkUrl).toContain("usercontent.jamendo.com");
	});

	it("drops results with no audio", async () => {
		mockFetch((url) => (url.host === "api.jamendo.com" ? json({ ...jamendoSearch, results: jamendoSearch.results.map((t) => ({ ...t, audio: "" })) }) : undefined));
		expect(await jamendo.search("lofi", 5, env, signal())).toEqual([]);
	});

	it("resolves a stream URL by track id", async () => {
		const spy = mockFetch(jamendoApi);
		expect(await jamendo.streamUrl("1545361", env, signal())).toContain("storage.jamendo.com/?trackid=1545361");
		expect(calledUrls(spy)[0].searchParams.get("id")).toBe("1545361");
	});

	it("rejects a non-numeric id without a request", async () => {
		const spy = mockFetch();
		expect(await jamendo.streamUrl("not-a-number", env, signal())).toBeNull();
		expect(spy).not.toHaveBeenCalled();
	});
});

describe("jiosaavn", () => {
	const api = (body: unknown, status = 200) => (url: URL) => (url.host === "www.jiosaavn.com" ? html(body, status) : undefined);
	const [first] = jiosaavnSearch.results;
	// One recorded result with the given fields replaced or removed (undefined).
	const song = (patch: Record<string, unknown> = {}, info: Record<string, unknown> = {}) => ({
		...first,
		...patch,
		more_info: { ...first.more_info, ...info },
	});

	it("searches jiosaavn.com's own endpoint with the query and page size", async () => {
		const spy = mockFetch(fixtures);
		await jiosaavn.search("blinding lights", 25, env, signal());
		const url = calledUrls(spy)[0];
		expect(`${url.origin}${url.pathname}`).toBe("https://www.jiosaavn.com/api.php");
		expect(Object.fromEntries(url.searchParams)).toMatchObject({ __call: "search.getResults", api_version: "4", q: "blinding lights", n: "25" });
	});

	it("maps a recorded song (served as text/html, like the real API) into a Track", async () => {
		mockFetch(fixtures);
		const tracks = await jiosaavn.search("blinding lights the weeknd", 10, env, signal());
		expect(tracks).toHaveLength(10);
		expect(tracks[0]).toEqual({
			id: "jiosaavn:fW-Mxsnu",
			source: "jiosaavn",
			sourceId: "fW-Mxsnu",
			title: "Blinding Lights",
			artist: "The Weeknd",
			album: "After Hours",
			artworkUrl: "https://c.saavncdn.com/077/After-Hours-English-2020-20260804045014-150x150.jpg",
			durationMs: 200_000,
			streamUrl: null,
			mbid: null,
			playable: false,
			deepLink: "https://www.jiosaavn.com/song/blinding-lights/Fj9GfAxDWUY",
		});
	});

	it("decodes HTML entities and joins every primary artist", async () => {
		mockFetch(api(jiosaavnRaatBhar));
		const t = (await jiosaavn.search("raat bhar", 10, env, signal())).find((t) => t.sourceId === "8oqXkCHu")!;
		expect(t.title).toBe('Raat Bhar (From "De De Pyaar De 2")');
		expect(t.album).toBe('Raat Bhar (From "De De Pyaar De 2")');
		expect(t.artist).toBe("Aditya Rikhari, Payal Dev, Aditya Dev, Kumaar");
	});

	it("never yields a stream: the encrypted media and preview fields are ignored", async () => {
		// The recorded values are redacted; put real-looking URLs back so a leak would show.
		const media = Object.fromEntries(
			["encrypted_media_url", "encrypted_cache_url", "encrypted_drm_media_url", "encrypted_drm_cache_url", "vlink"].map((k) => [k, `https://media.example/${k}.mp4`]),
		);
		mockFetch(api({ ...jiosaavnSearch, results: jiosaavnSearch.results.map((r) => ({ ...r, more_info: { ...r.more_info, ...media } })) }));
		const tracks = await jiosaavn.search("blinding lights the weeknd", 10, env, signal());
		expect(tracks).toHaveLength(10);
		for (const t of tracks) expect(t).toMatchObject({ playable: false, streamUrl: null });
		expect(JSON.stringify(tracks)).not.toContain("media.example");

		vi.restoreAllMocks();
		const spy = mockFetch();
		expect(await jiosaavn.streamUrl("fW-Mxsnu", env, signal())).toBeNull();
		expect(spy).not.toHaveBeenCalled();
	});

	it("skips unusable results and tolerates missing optional fields", async () => {
		mockFetch(
			api({
				results: [
					song({ id: undefined }),
					song({ title: "  " }),
					song({ type: "album" }),
					null,
					song({ id: "partial", image: "http://insecure.example/x.jpg", perma_url: 42 }, { artistMap: undefined, album: "", duration: "n/a" }),
					{ ...first, id: "bare", more_info: undefined },
				],
			}),
		);
		const tracks = await jiosaavn.search("x", 10, env, signal());
		expect(tracks.map((t) => t.sourceId)).toEqual(["partial", "bare"]);
		for (const t of tracks) {
			expect(t).toMatchObject({ title: "Blinding Lights", artist: "", album: null, durationMs: null, playable: false, streamUrl: null });
		}
		expect(tracks[0]).toMatchObject({ artworkUrl: null, deepLink: null }); // only https URLs are kept
	});

	it("returns nothing for a query with no matches", async () => {
		mockFetch(api({ total: 0, start: 1, results: [] })); // recorded live for a nonsense query
		expect(await jiosaavn.search("zzqxqzzqx nonsense qqq", 10, env, signal())).toEqual([]);
	});

	it("reports API errors returned with HTTP 200, and malformed bodies", async () => {
		mockFetch(api({ error: { code: "INPUT_MISSING", msg: "One or more required field missing:q" } })); // recorded live
		await expect(jiosaavn.search("x", 10, env, signal())).rejects.toThrow("jiosaavn error INPUT_MISSING");

		vi.restoreAllMocks();
		mockFetch(api({ total: 3 }));
		await expect(jiosaavn.search("x", 10, env, signal())).rejects.toThrow("without a results list");

		vi.restoreAllMocks();
		mockFetch(() => new Response("<html>maintenance</html>", { headers: { "content-type": "text/html" } }));
		await expect(jiosaavn.search("x", 10, env, signal())).rejects.toThrow();
	});

	it("reports HTTP errors", async () => {
		mockFetch(api({}, 503));
		await expect(jiosaavn.search("x", 10, env, signal())).rejects.toBeInstanceOf(HttpError);
	});
});

describe("youtube", () => {
	it("fails without an API key", async () => {
		await expect(youtube.search("x", 5, { ...env, YOUTUBE_API_KEY: "" }, signal())).rejects.toThrow("YOUTUBE_API_KEY");
	});

	it("decodes the HTML entities YouTube puts in titles", () => {
		expect(decodeEntities("Rock &amp; Roll &#39;n&#x27; &quot;Soul&quot; &bogus;")).toBe(`Rock & Roll 'n' "Soul" &bogus;`);
	});
});
