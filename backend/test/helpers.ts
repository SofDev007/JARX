import { vi } from "vitest";
import archiveSearch from "./fixtures/archive_search.json";
import audiusSearch from "./fixtures/audius_search.json";
import audiusStream from "./fixtures/audius_stream.json";
import jiosaavnSearch from "./fixtures/jiosaavn_search.json";

// Real responses recorded from the live APIs (see test/fixtures).
const archiveFiles = import.meta.glob<{ default: unknown }>("./fixtures/archive_files_*.json", { eager: true });

export const json = (body: unknown, status = 200) => Response.json(body, { status });

/** JSON the way JioSaavn sends it: labelled text/html. */
export const html = (body: unknown, status = 200) =>
	new Response(JSON.stringify(body), { status, headers: { "content-type": "text/html; charset=UTF-8" } });

/** A request that never answers, but rejects on abort like real fetch. */
export const hang = (signal?: AbortSignal | null) =>
	new Promise<Response>((_, reject) => signal?.addEventListener("abort", () => reject(signal.reason)));

type Route = (url: URL, signal?: AbortSignal | null) => Response | Promise<Response> | undefined;

/** Serves every source from recorded fixtures. */
export const fixtures: Route = (url) => {
	if (url.host === "api.audius.co" && url.pathname === "/v1/tracks/search") return json(audiusSearch);
	if (url.host === "api.audius.co" && url.pathname.endsWith("/stream")) return json(audiusStream);
	if (url.host === "archive.org" && url.pathname === "/advancedsearch.php") return json(archiveSearch);
	const files = url.host === "archive.org" && url.pathname.match(/^\/metadata\/([^/]+)\/files$/);
	if (files) return json(archiveFiles[`./fixtures/archive_files_${decodeURIComponent(files[1])}.json`]?.default ?? { result: [] });
	if (url.host === "api.jamendo.com") return json({ headers: { status: "success", code: 0, error_message: "", warnings: "", results_count: 0 }, results: [] });
	if (url.host === "www.googleapis.com") return json({ items: [] });
	if (url.host === "www.jiosaavn.com" && url.searchParams.get("__call") === "search.getResults") return html(jiosaavnSearch);
};

/** Mocks global fetch; each route is tried in order, unmatched requests fail the test. */
export function mockFetch(...routes: Route[]) {
	return vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
		const url = new URL(input instanceof Request ? input.url : String(input));
		for (const route of routes) {
			const res = await route(url, init?.signal);
			if (res) return res;
		}
		throw new Error(`unexpected fetch to ${url.host}${url.pathname}`);
	});
}

/** Hosts (and paths) fetched through a mockFetch spy, for asserting which sources were called. */
export const calledUrls = (spy: ReturnType<typeof mockFetch>) =>
	spy.mock.calls.map(([input]) => new URL(input instanceof Request ? input.url : String(input)));
