import { z } from "zod";

export const SOURCES = ["audius", "jamendo", "archive", "youtube"] as const;
export type Source = (typeof SOURCES)[number];

// Normalized track model. Optional fields default to null so stored JSON always
// has the same shape. `id` is always derived as "<source>:<sourceId>".
export const trackSchema = z
	.object({
		source: z.enum(SOURCES),
		sourceId: z.string().min(1).max(1000),
		title: z.string().min(1).max(500),
		artist: z.string().max(500),
		album: z.string().max(500).nullable().default(null),
		artworkUrl: z.url().max(2000).nullable().default(null),
		durationMs: z.number().int().nonnegative().nullable().default(null),
		streamUrl: z.url().max(4000).nullable().default(null),
		mbid: z.string().max(64).nullable().default(null),
		playable: z.boolean(),
		deepLink: z.url().max(2000).nullable().default(null),
	})
	.transform((t) => ({ id: `${t.source}:${t.sourceId}`, ...t }));
export type Track = z.output<typeof trackSchema>;

type Env = CloudflareBindings;

export interface Adapter {
	search(q: string, limit: number, env: Env, signal: AbortSignal): Promise<Track[]>;
	/** Fresh playable URL, or null when the source says the track doesn't exist. */
	streamUrl(sourceId: string, env: Env, signal: AbortSignal): Promise<string | null>;
}

export class HttpError extends Error {
	constructor(readonly status: number, host: string) {
		super(`${host} responded ${status}`); // host only: query strings carry API keys
	}
}

async function getJson(url: string, signal: AbortSignal): Promise<any> {
	const res = await fetch(url, { signal, headers: { accept: "application/json" } });
	if (!res.ok) throw new HttpError(res.status, new URL(url).host);
	return res.json();
}

const track = (t: Omit<Track, "id" | "mbid">): Track => ({ id: `${t.source}:${t.sourceId}`, mbid: null, ...t });

// --- Audius -----------------------------------------------------------------
// GET https://api.audius.co now lists only itself ({"data":["https://api.audius.co"]}),
// so fetching the list per request just adds latency. discoveryprovider.audius.co
// still serves the same /v1 API and is the fallback when the primary fails.
export const AUDIUS_HOSTS = ["https://api.audius.co", "https://discoveryprovider.audius.co"];

async function audiusGet(path: string, signal: AbortSignal): Promise<any> {
	let lastError: unknown;
	for (const host of AUDIUS_HOSTS) {
		try {
			return await getJson(`${host}/v1${path}${path.includes("?") ? "&" : "?"}app_name=JARX`, signal);
		} catch (e) {
			// A 4xx is a real answer and timeouts leave no budget: only retry host failures.
			if (signal.aborted || (e instanceof HttpError && e.status < 500)) throw e;
			lastError = e;
		}
	}
	throw lastError;
}

export const audius: Adapter = {
	async search(q, limit, _env, signal) {
		const { data } = await audiusGet(`/tracks/search?query=${encodeURIComponent(q)}&limit=${limit}`, signal);
		return (data as any[])
			.filter((t) => t.is_streamable && t.access?.stream !== false)
			.map((t) =>
				track({
					source: "audius",
					sourceId: t.id,
					title: t.title,
					artist: t.user?.name || t.user?.handle || "",
					album: null,
					artworkUrl: t.artwork?.["480x480"] ?? null,
					durationMs: typeof t.duration === "number" ? t.duration * 1000 : null,
					streamUrl: t.stream?.url ?? null, // signed and short-lived; use the stream route before playback
					playable: true,
					deepLink: null,
				}),
			);
	},
	async streamUrl(id, _env, signal) {
		try {
			const { data } = await audiusGet(`/tracks/${encodeURIComponent(id)}/stream?no_redirect=true`, signal);
			return typeof data === "string" ? data : null;
		} catch (e) {
			if (e instanceof HttpError && (e.status === 400 || e.status === 404)) return null;
			throw e;
		}
	},
};

// --- Jamendo ----------------------------------------------------------------
async function jamendoTracks(params: string, env: Env, signal: AbortSignal): Promise<any[]> {
	if (!env.JAMENDO_CLIENT_ID) throw new Error("JAMENDO_CLIENT_ID is not set");
	const url = `https://api.jamendo.com/v3.0/tracks/?client_id=${encodeURIComponent(env.JAMENDO_CLIENT_ID)}&format=json&audioformat=mp32&imagesize=300&${params}`;
	const body = await getJson(url, signal);
	// Jamendo reports errors in the body with HTTP 200.
	if (body.headers?.status !== "success") throw new Error(`jamendo error ${body.headers?.code}: ${body.headers?.error_message}`);
	return body.results;
}

export const jamendo: Adapter = {
	async search(q, limit, env, signal) {
		const results = await jamendoTracks(`limit=${limit}&search=${encodeURIComponent(q)}`, env, signal);
		return results
			.filter((t) => t.audio)
			.map((t) =>
				track({
					source: "jamendo",
					sourceId: String(t.id),
					title: t.name,
					artist: t.artist_name ?? "",
					album: t.album_name || null,
					artworkUrl: t.image || t.album_image || null,
					durationMs: typeof t.duration === "number" ? t.duration * 1000 : null,
					streamUrl: t.audio,
					playable: true,
					deepLink: null,
				}),
			);
	},
	async streamUrl(id, env, signal) {
		if (!/^\d+$/.test(id)) return null;
		const [t] = await jamendoTracks(`id=${id}`, env, signal);
		return t?.audio || null;
	},
};

// --- Internet Archive -------------------------------------------------------
// sourceId = "<identifier>/<file name>"; download URLs are stable, not signed.
const ARCHIVE_ITEMS = 5; // items whose file lists we fetch per search
const ARCHIVE_FILES_PER_ITEM = 10;

export const archiveUrl = (sourceId: string) =>
	`https://archive.org/download/${sourceId.split("/").map(encodeURIComponent).join("/")}`;

const first = (v: unknown) => (Array.isArray(v) ? v[0] : v) as string | undefined;

// File `length` is seconds ("687.91") or sometimes "mm:ss" / "h:mm:ss".
function lengthMs(v: unknown): number | null {
	if (typeof v !== "string" || !v) return null;
	const secs = v.split(":").reduce((acc, part) => acc * 60 + Number(part), 0);
	return Number.isFinite(secs) ? Math.round(secs * 1000) : null;
}

export const archive: Adapter = {
	async search(q, limit, _env, signal) {
		// Keep letters/numbers only so user input can't break the Lucene query.
		const terms = q.replace(/[^\p{L}\p{N}\s]/gu, " ").trim();
		if (!terms) return [];
		// Checked live: full-text relevance ranks auto-uploaded podcasts whose MP3s are all
		// private first. Matching title/creator, requiring VBR MP3 and sorting by downloads
		// returns relevant items with public files.
		const query = encodeURIComponent(`(title:(${terms}) OR creator:(${terms})) AND mediatype:audio AND format:"VBR MP3"`);
		const rows = Math.min(limit, ARCHIVE_ITEMS);
		const { response } = await getJson(
			`https://archive.org/advancedsearch.php?q=${query}&fl[]=identifier&fl[]=title&fl[]=creator&rows=${rows}&sort[]=downloads+desc&output=json`,
			signal,
		);
		const items = await Promise.allSettled(
			(response.docs as any[]).map(async (doc) => {
				const { result = [] } = await getJson(`https://archive.org/metadata/${encodeURIComponent(doc.identifier)}/files`, signal);
				const mp3s = (result as any[]).filter((f) => /\.mp3$/i.test(f.name) && f.private !== "true");
				const vbr = mp3s.filter((f) => f.format === "VBR MP3"); // skip lower-bitrate duplicates
				return (vbr.length ? vbr : mp3s).slice(0, ARCHIVE_FILES_PER_ITEM).map((f) => {
					const sourceId = `${doc.identifier}/${f.name}`;
					return track({
						source: "archive",
						sourceId,
						title: f.title || first(doc.title) || f.name.replace(/\.mp3$/i, ""),
						artist: f.artist || f.creator || first(doc.creator) || "",
						album: f.album || first(doc.title) || null,
						artworkUrl: `https://archive.org/services/img/${encodeURIComponent(doc.identifier)}`,
						durationMs: lengthMs(f.length),
						streamUrl: archiveUrl(sourceId),
						playable: true,
						deepLink: null,
					});
				});
			}),
		);
		return items.flatMap((r) => (r.status === "fulfilled" ? r.value : []));
	},
	async streamUrl(id) {
		return id.includes("/") ? archiveUrl(id) : null;
	},
};

// --- YouTube (metadata only: never extract or proxy audio) ------------------
const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };
export const decodeEntities = (s: string) =>
	s.replace(/&(#x[\da-f]+|#\d+|\w+);/gi, (m, e: string) =>
		e[0] !== "#" ? (ENTITIES[e.toLowerCase()] ?? m) : String.fromCodePoint(e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : Number(e.slice(1))),
	);

export const youtube: Adapter = {
	async search(q, limit, env, signal) {
		if (!env.YOUTUBE_API_KEY) throw new Error("YOUTUBE_API_KEY is not set");
		const url =
			"https://www.googleapis.com/youtube/v3/search?part=snippet&type=video&videoCategoryId=10" +
			`&maxResults=${Math.min(limit, 50)}&q=${encodeURIComponent(q)}&key=${encodeURIComponent(env.YOUTUBE_API_KEY)}`;
		const { items = [] } = await getJson(url, signal);
		return (items as any[])
			.filter((it) => it.id?.videoId)
			.map((it) =>
				track({
					source: "youtube",
					sourceId: it.id.videoId,
					title: decodeEntities(it.snippet.title),
					artist: decodeEntities(it.snippet.channelTitle ?? ""),
					album: null,
					artworkUrl: (it.snippet.thumbnails?.high ?? it.snippet.thumbnails?.medium ?? it.snippet.thumbnails?.default)?.url ?? null,
					durationMs: null,
					streamUrl: null,
					playable: false,
					deepLink: `https://www.youtube.com/watch?v=${it.id.videoId}`,
				}),
			);
	},
	async streamUrl() {
		return null; // never playable; the route answers with the deep link instead
	},
};

export const ADAPTERS: Record<Source, Adapter> = { audius, jamendo, archive, youtube };
