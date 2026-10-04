import { archive, audius, jamendo, jiosaavn, youtube, youtubeWatchUrl, type Adapter } from "./sources";

/** audio: a music result JARX ranks as such. video: a separate class of result (YouTube). */
export type Kind = "audio" | "video";

/**
 * local: a file on the device. native: JARX streams it in its own player.
 * embed: plays only in the provider's own player, so there is never a stream URL to resolve.
 */
export type PlaybackType = "local" | "native" | "embed";

export interface Provider {
	name: string;
	/** Disabled providers keep their adapter, fixtures and tests, but search and import never query them. */
	enabled: boolean;
	kind: Kind;
	/** Multiplies the fuzzy match score in rank(). */
	weight: number;
	playback: PlaybackType;
	adapter: Adapter;
	/** Where to send the user for a source JARX can't play itself. */
	deepLink?: (sourceId: string) => string;
}

// The one list of providers. Order matters: sources are queried and merged in this order,
// which decides ties in rank().
const registry = {
	// Metadata only: its audio is protected media, so tracks open JioSaavn instead of playing here.
	// Weight from live checks (6 queries, Indian and international): the intended original led each
	// one, versions are labelled in titles, a nonsense query returns nothing. That's Jamendo-level
	// trust, kept under Audius so an equally good match JARX can actually play sorts first.
	jiosaavn: { name: "JioSaavn", enabled: true, kind: "audio", weight: 0.95, playback: "embed", adapter: jiosaavn },
	// Legacy: to be disabled (never deleted) once their replacements exist.
	audius: { name: "Audius", enabled: true, kind: "audio", weight: 1, playback: "native", adapter: audius },
	jamendo: { name: "Jamendo", enabled: true, kind: "audio", weight: 0.95, playback: "native", adapter: jamendo },
	archive: { name: "Internet Archive", enabled: true, kind: "audio", weight: 0.7, playback: "native", adapter: archive },
	// Metadata only: never extract, proxy or download YouTube audio.
	youtube: { name: "YouTube", enabled: true, kind: "video", weight: 0.9, playback: "embed", adapter: youtube, deepLink: youtubeWatchUrl },
} satisfies Record<string, Provider>;

export type Source = keyof typeof registry;
export const PROVIDERS: Record<Source, Provider> = registry;
export const SOURCES = Object.keys(registry) as [Source, ...Source[]];

/** Enabled providers, optionally only those of one kind, in registry order. */
export const enabledSources = (kind?: Kind): Source[] =>
	SOURCES.filter((s) => PROVIDERS[s].enabled && (!kind || PROVIDERS[s].kind === kind));
