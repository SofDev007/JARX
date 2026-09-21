import { ADAPTERS, type Source, type Track } from "./sources";

export const WEIGHT: Record<Source, number> = { audius: 1, jamendo: 0.95, archive: 0.7, youtube: 0.9 };
export const TIMEOUT_MS = 2500;
export const MIN_SCORE = 0.5; // below this a result is dropped
export const HIT_SCORE = 0.75; // a playable result at or above this counts as a confident match
const CACHE_TTL_MS = 24 * 60 * 60 * 1000;
const PLAYABLE_SOURCES: Source[] = ["audius", "jamendo", "archive"];

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
	const best = new Map<string, ScoredTrack>();
	for (const { score: _, ...t } of tracks as ScoredTrack[]) {
		const score = Math.round(similarity(query, t.title, t.artist) * WEIGHT[t.source] * 1000) / 1000;
		if (score < MIN_SCORE) continue;
		const key = `${normalize(t.title)}|${normalize(t.artist)}`;
		const prev = best.get(key);
		if (!prev || score > prev.score) best.set(key, { ...t, score });
	}
	return [...best.values()].sort((a, b) => b.score - a.score).slice(0, limit);
}

/** Query sources in parallel; each gets its own timeout and a failure only drops that source. */
export async function gather(env: CloudflareBindings, q: string, limit: number, sources: Source[]): Promise<Track[]> {
	const settled = await Promise.allSettled(sources.map((s) => ADAPTERS[s].search(q, limit, env, AbortSignal.timeout(TIMEOUT_MS))));
	return settled.flatMap((r, i) => {
		if (r.status === "fulfilled") return r.value;
		console.warn(`source ${sources[i]} failed: ${String(r.reason).replace(/(key|client_id)=[^&\s]+/g, "$1=***")}`);
		return [];
	});
}

const hasHit = (results: ScoredTrack[]) => results.some((t) => t.playable && t.score >= HIT_SCORE);

async function sha256(s: string): Promise<string> {
	const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
	return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Full search: D1 cache (24h) → playable sources → YouTube only if nothing
 * playable is a confident match (protects the 100 searches/day quota).
 */
export async function search(env: CloudflareBindings, q: string, limit: number): Promise<{ results: ScoredTrack[]; cached: boolean }> {
	const db = env.jarx_db;
	const hash = await sha256(`${normalize(q)}|${limit}`);
	const now = Date.now();
	const hit = await db
		.prepare("SELECT results_json FROM search_cache WHERE query_hash = ? AND fetched_at > ?")
		.bind(hash, now - CACHE_TTL_MS)
		.first<string>("results_json");
	if (hit) return { results: JSON.parse(hit), cached: true };

	let results = rank(q, await gather(env, q, limit, PLAYABLE_SOURCES), limit);
	if (!hasHit(results)) results = rank(q, [...results, ...(await gather(env, q, limit, ["youtube"]))], limit);

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
 * Best confident playable match for an import row, or null. Skips archive
 * (weight 0.7 < HIT_SCORE) and YouTube (quota). When the row names an artist
 * the candidate's artist must match too: covers like "The Weeknd Blinding
 * Lights [COVER]" by "DJ-M" otherwise score high on title+artist text alone.
 */
export async function resolveOne(env: CloudflareBindings, q: string, artist = ""): Promise<Track | null> {
	const best = rank(q, await gather(env, q, 5, ["audius", "jamendo"]), 5).find(
		(t) => t.score >= HIT_SCORE && (!artist || similarity(artist, t.artist, "") >= MIN_SCORE),
	);
	if (!best) return null;
	const { score: _, ...t } = best;
	return t;
}
