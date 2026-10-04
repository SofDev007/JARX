import { enabledSources, PROVIDERS, type Source } from "./providers";
import type { Track } from "./track";

export const TIMEOUT_MS = 2500;
export const MIN_SCORE = 0.5; // below this a result is dropped
export const HIT_SCORE = 0.75; // a playable result at or above this counts as a confident match
const CACHE_TTL_MS = 24 * 60 * 60 * 1000;

export type ScoredTrack = Track & { score: number };

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

/** Score, drop below MIN_SCORE, dedupe on normalized title+artist keeping the best, sort. */
export function rank(query: string, tracks: Track[], limit: number): ScoredTrack[] {
	const asked = flat(query);
	const best = new Map<string, ScoredTrack>();
	for (const { score: _, ...t } of tracks as ScoredTrack[]) {
		// Only demote when the query itself didn't ask for that marker.
		const marker = (t.title.match(VERSION_RE) ?? t.artist.match(VERSION_RE))?.[0];
		const penalty = marker && !asked.includes(flat(marker)) ? VERSION_PENALTY : 1;
		const score = Math.round(similarity(query, t.title, t.artist) * PROVIDERS[t.source].weight * penalty * 1000) / 1000;
		if (score < MIN_SCORE) continue;
		const key = `${normalize(t.title)}|${normalize(t.artist)}`;
		const prev = best.get(key);
		if (!prev || score > prev.score) best.set(key, { ...t, score });
	}
	return [...best.values()].sort((a, b) => b.score - a.score).slice(0, limit);
}

/** Query sources in parallel; each gets its own timeout and a failure only drops that source. */
export async function gather(env: CloudflareBindings, q: string, limit: number, sources: Source[]): Promise<Track[]> {
	const settled = await Promise.allSettled(sources.map((s) => PROVIDERS[s].adapter.search(q, limit, env, AbortSignal.timeout(TIMEOUT_MS))));
	const per = settled.map((r, i) => {
		if (r.status === "fulfilled") return r.value;
		console.warn(`source ${sources[i]} failed: ${String(r.reason).replace(/(key|client_id)=[^&\s]+/g, "$1=***")}`);
		return [] as Track[];
	});
	// Jamendo intermittently answers 200/"success" with zero results for a query that works
	// seconds later. Only worth a line when a sibling source did find something.
	const j = sources.indexOf("jamendo");
	if (j >= 0 && !per[j].length && per.some((p) => p.length)) console.warn(`jamendo returned 0 results for "${q}" while another source had hits`);
	return per.flat();
}

const hasHit = (results: ScoredTrack[]) => results.some((t) => t.playable && t.score >= HIT_SCORE);

async function sha256(s: string): Promise<string> {
	const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
	return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Full search: D1 cache (24h) → enabled audio providers → enabled video providers (YouTube)
 * only if nothing playable is a confident match (protects the 100 searches/day quota).
 */
export async function search(env: CloudflareBindings, q: string, limit: number): Promise<{ results: ScoredTrack[]; cached: boolean }> {
	const db = env.jarx_db;
	// Keyed on the enabled providers too, so toggling one never serves answers cached under the old set.
	const hash = await sha256(`${normalize(q)}|${limit}|${enabledSources().join(",")}`);
	const now = Date.now();
	const hit = await db
		.prepare("SELECT results_json FROM search_cache WHERE query_hash = ? AND fetched_at > ?")
		.bind(hash, now - CACHE_TTL_MS)
		.first<string>("results_json");
	if (hit) return { results: JSON.parse(hit), cached: true };

	let results = rank(q, await gather(env, q, limit, enabledSources("audio")), limit);
	if (!hasHit(results)) results = rank(q, [...results, ...(await gather(env, q, limit, enabledSources("video")))], limit);

	// Don't pin an empty (possibly outage-caused) result for a day.
	if (results.length) {
		await db.batch([
			db
				.prepare("INSERT OR REPLACE INTO search_cache (query_hash, results_json, fetched_at) VALUES (?, ?, ?)")
				.bind(hash, JSON.stringify(results), now),
			db.prepare("DELETE FROM search_cache WHERE fetched_at <= ?").bind(now - CACHE_TTL_MS),
		]);
	}
	return { results, cached: false };
}

/**
 * Best confident playable match for an import row, or null. Queries only enabled
 * audio providers whose weight can reach HIT_SCORE at all (so not archive at 0.7,
 * which also saves its subrequests) and never video ones (YouTube quota). When the
 * row names an artist the candidate's artist must match too: covers like "The
 * Weeknd Blinding Lights [COVER]" by "DJ-M" otherwise score high on title+artist text alone.
 */
export async function resolveOne(env: CloudflareBindings, q: string, artist = ""): Promise<Track | null> {
	const sources = enabledSources("audio").filter((s) => PROVIDERS[s].weight >= HIT_SCORE);
	const best = rank(q, await gather(env, q, 5, sources), 5).find(
		(t) => t.score >= HIT_SCORE && (!artist || similarity(artist, t.artist, "") >= MIN_SCORE),
	);
	if (!best) return null;
	const { score: _, ...t } = best;
	return t;
}
