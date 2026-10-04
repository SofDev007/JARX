import { z } from "zod";
import { PROVIDERS, SOURCES, type PlaybackType, type Source } from "./providers";

// Normalized track model: what D1 stores as track_json and the API serves. Optional fields
// default to null so stored JSON always has the same shape. `id` is always derived as "<source>:<sourceId>".
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

/** One provider's copy of a song, and how JARX can play it. */
export type TrackSource = {
	provider: Source;
	sourceId: string;
	playback: PlaybackType;
	/** JARX can play it right now. False for embed sources and for import placeholders ("youtube:search:<query>"). */
	playable: boolean;
	streamUrl: string | null;
	deepLink: string | null;
};

/**
 * A song's metadata plus every provider copy JARX knows of. Not stored or served yet: D1 and the
 * API still carry flat Tracks, and toCanonical lifts one into this shape without losing a field.
 * `id` stays the primary (first) source's "<source>:<sourceId>", so favorites and playlists keep their keys.
 */
export type CanonicalTrack = Pick<Track, "id" | "title" | "artist" | "album" | "artworkUrl" | "durationMs" | "mbid"> & {
	sources: [TrackSource, ...TrackSource[]];
};

export const toCanonical = ({ source, sourceId, playable, streamUrl, deepLink, ...meta }: Track): CanonicalTrack => ({
	...meta,
	sources: [{ provider: source, sourceId, playback: PROVIDERS[source].playback, playable, streamUrl, deepLink }],
});
