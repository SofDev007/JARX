import { enabledSources, PROVIDERS, streamable, type Source } from "./providers";
import { HttpError } from "./sources";
import { toSource, type CanonicalTrack, type Track } from "./track";

export const TIMEOUT_MS = 2500;
export const MIN_SCORE = 0.5; // below this a result is dropped
export const HIT_SCORE = 0.75; // a playable result at or above this counts as a confident match
const CACHE_TTL_MS = 24 * 60 * 60 * 1000;

/** A ranked result: the best copy as a flat Track, plus every copy found in `sources` (that one first). */
export type ScoredTrack = Track & CanonicalTrack & { score: number };

// "Lo-Fi", "lofi" and "LOFI!" normalize alike; separators become token breaks.
export const normalize = (s: string) =>
	s
		.normalize("NFKD")
		.replace(/\p{M}/gu, "")
		.toLowerCase()
		.replace(/['’.-]/g, "")
		.replace(/[^\p{L}\p{N}]+/gu, " ")
		.trim();

const tokens = (s: string) => normalize(s).split(" ").filter(Boolean);

function levenshtein(a: string, b: string): number {
	let prev = Array.from({ length: b.length + 1 }, (_, i) => i);
	for (let i = 1; i <= a.length; i++) {
		const cur = [i];
		for (let j = 1; j <= b.length; j++) cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
		prev = cur;
	}
	return prev[b.length];
}

// Typo-tolerant token match; weak partial matches count as no match.
function tokenSim(a: string, b: string): number {
	if (a === b) return 1;
	const s = 1 - levenshtein(a, b) / Math.max(a.length, b.length);
	return s >= 0.7 ? s : 0;
}

// Audius is full of covers/remixes titled like the original ("Blinding Lights - [COVER]"),
// and tribute acts hide in the artist field ("Weeknd Tribute Band"), so both are checked.
const VERSION_RE =
	/\b(cover|remix(ed)?|flip|bootleg|mashup|karaoke|instrumental|tribute|nightcore|sped[ -]?up|slowed|reverb|8d|made famous by|originally performed by)\b/i;
export const VERSION_PENALTY = 0.7;

// Spacing-insensitive, so a "sped up" title counts as asked-for by a "sped-up" query.
const flat = (s: string) => normalize(s).replace(/ /g, "");

const coverage = (from: string[], to: string[]) =>
	from.reduce((sum, a) => sum + Math.max(0, ...to.map((b) => tokenSim(a, b))), 0) / from.length;

/**
 * Fuzzy similarity (0..1) of a query to "title artist": mostly how much of the
 * query the candidate covers, plus a little for how much of the candidate the
 * query explains (so tighter matches rank higher).
 */
export function similarity(query: string, title: string, artist: string): number {
	const q = tokens(query);
	const c = tokens(`${title} ${artist}`);
	if (!q.length || !c.length) return 0;
	return 0.75 * coverage(q, c) + 0.25 * coverage(c, q);
}

/**
 * Score, drop below MIN_SCORE, merge copies with the same normalized title+artist, sort.
 * The lead is what the app plays, so a copy JARX can play leads over one it can't (a JioSaavn
 * copy never hides a playable one); then the best score, ties to the first seen. The others
 * stay as alternate sources.
 */
export function rank(query: string, tracks: Track[], limit: number): ScoredTrack[] {
	const asked = flat(query);
	const merged = new Map<string, ScoredTrack>();
	for (const t of tracks) {
		// Only demote when the query itself didn't ask for that marker.
		const marker = (t.title.match(VERSION_RE) ?? t.artist.match(VERSION_RE))?.[0];
		const penalty = marker && !asked.includes(flat(marker)) ? VERSION_PENALTY : 1;
		const score = Math.round(similarity(query, t.title, t.artist) * PROVIDERS[t.source].weight * penalty * 1000) / 1000;
		if (score < MIN_SCORE) continue;
		const key = `${normalize(t.title)}|${normalize(t.artist)}`;
		const prev = merged.get(key);
		if (!prev) merged.set(key, { ...t, score, sources: [toSource(t)] });
		else if (t.playable !== prev.playable ? t.playable : score > prev.score) merged.set(key, { ...t, score, sources: [toSource(t), ...prev.sources] });
		else prev.sources.push(toSource(t));
	}
	return [...merged.values()].sort((a, b) => b.score - a.score).slice(0, limit);
}

/** Query sources in parallel; each gets its own timeout and a failure only drops that source. */
export async function gather(env: CloudflareBindings, q: string, limit: number, sources: Source[]): Promise<Track[]> {
	return (await settle(env, q, limit, sources)).tracks;
}

/** gather(), plus why the failed sources failed. */
async function settle(env: CloudflareBindings, q: string, limit: number, sources: Source[]): Promise<{ tracks: Track[]; errors: unknown[] }> {
	const settled = await Promise.allSettled(sources.map((s) => PROVIDERS[s].adapter.search(q, limit, env, AbortSignal.timeout(TIMEOUT_MS))));
	const errors: unknown[] = [];
	const per = settled.map((r, i) => {
		if (r.status === "fulfilled") return r.value.map((t) => ({ ...t, playable: streamable(t.source) }));
		errors.push(r.reason);
		console.warn(`source ${sources[i]} failed: ${String(r.reason).replace(/(key|client_id)=[^&\s]+/g, "$1=***")}`);
		return [] as Track[];
	});
	// Jamendo intermittently answers 200/"success" with zero results for a query that works
	// seconds later. Only worth a line when a sibling source did find something.
	const j = sources.indexOf("jamendo");
	if (j >= 0 && !per[j].length && per.some((p) => p.length)) console.warn(`jamendo returned 0 results for "${q}" while another source had hits`);
	return { tracks: per.flat(), errors };
}

/** Why the video half of a search is empty when it failed, for the app to say so. */
export type VideoError = "quota_exceeded" | "unavailable";
export type SearchResults = { music: ScoredTrack[]; videos: ScoredTrack[]; videoError: VideoError | null };

const isQuotaError = (e: unknown) => e instanceof HttpError && e.reason === "quotaExceeded";

async function sha256(s: string): Promise<string> {
	const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
	return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Full search: D1 cache (24h), else music (enabled audio providers) and videos (enabled video
 * providers: YouTube) fetched in parallel and ranked apart, so videos never mix into the music.
 * Each uncached search spends one of YouTube's 100 daily search.list calls; the cache keeps
 * repeats free.
 */
export async function search(env: CloudflareBindings, q: string, limit: number): Promise<SearchResults & { cached: boolean }> {
	const db = env.jarx_db;
	// Keyed on the enabled providers and their playback types too, so changing either never
	// serves answers cached under the old setup.
	const providers = enabledSources().map((s) => `${s}:${PROVIDERS[s].playback}`);
	const hash = await sha256(`${normalize(q)}|${limit}|${providers.join(",")}`);
	const now = Date.now();
	const hit = await db
		.prepare("SELECT results_json FROM search_cache WHERE query_hash = ? AND fetched_at > ?")
		.bind(hash, now - CACHE_TTL_MS)
		.first<string>("results_json");
	if (hit) return { ...(JSON.parse(hit) as SearchResults), cached: true };

	const [music, video] = await Promise.all([
		settle(env, q, limit, enabledSources("audio")),
		settle(env, q, limit, enabledSources("video")),
	]);
	const results: SearchResults = {
		music: rank(q, music.tracks, limit),
		videos: rank(q, video.tracks, limit),
		videoError: !video.errors.length ? null : video.errors.some(isQuotaError) ? "quota_exceeded" : "unavailable",
	};

	// Cache complete answers only. Never pin an empty (possibly outage-caused) one, nor one whose
	// videos failed (say, YouTube's daily quota ran out), so videos return once YouTube answers again.
	if ((results.music.length || results.videos.length) && !results.videoError) {
		await db.batch([
			db
				.prepare("INSERT OR REPLACE INTO search_cache (query_hash, results_json, fetched_at) VALUES (?, ?, ?)")
				.bind(hash, JSON.stringify(results), now),
			db.prepare("DELETE FROM search_cache WHERE fetched_at <= ?").bind(now - CACHE_TTL_MS),
		]);
	}
	return { ...results, cached: false };
}

/**
 * Best confident playable match for an import row, or null. Queries only enabled
 * audio providers JARX streams (`native`; so not JioSaavn, whose rows can't play
 * here and would push a 20-row chunk past the Free plan's 50 subrequests) whose
 * weight can reach HIT_SCORE at all (so not archive at 0.7), and never video ones
 * (YouTube quota). When the row names an artist the candidate's artist must match
 * too: covers like "The Weeknd Blinding Lights [COVER]" by "DJ-M" otherwise score
 * high on title+artist text alone.
 */
export async function resolveOne(env: CloudflareBindings, q: string, artist = ""): Promise<Track | null> {
	const sources = enabledSources("audio").filter((s) => PROVIDERS[s].playback === "native" && PROVIDERS[s].weight >= HIT_SCORE);
	const best = rank(q, await gather(env, q, 5, sources), 5).find(
		(t) => t.score >= HIT_SCORE && (!artist || similarity(artist, t.artist, "") >= MIN_SCORE),
	);
	if (!best) return null;
	const { score: _, sources: _sources, ...t } = best; // stored as a flat Track
	return t;
}
