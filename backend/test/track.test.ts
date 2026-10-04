import { describe, expect, it } from "vitest";
import { toCanonical, trackSchema, type Track } from "../src/track";

// track_json exactly as D1 holds it: written through trackSchema since 0001_init.
const stored = {
	audius: {
		id: "audius:ng9rl",
		source: "audius",
		sourceId: "ng9rl",
		title: "lofi type beat",
		artist: "bsdu",
		album: null,
		artworkUrl: "https://audius.example/480x480.jpg",
		durationMs: 120000,
		streamUrl: "https://api.audius.co/v1/tracks/cidstream/x?signature=y",
		mbid: null,
		playable: true,
		deepLink: null,
	},
	archive: {
		id: "archive:item/My Song #1.mp3",
		source: "archive",
		sourceId: "item/My Song #1.mp3",
		title: "My Song",
		artist: "Someone",
		album: "Item",
		artworkUrl: "https://archive.org/services/img/item",
		durationMs: 1000,
		streamUrl: "https://archive.org/download/item/My%20Song%20%231.mp3",
		mbid: null,
		playable: true,
		deepLink: null,
	},
	youtube: {
		id: "youtube:dQw4w9WgXcQ",
		source: "youtube",
		sourceId: "dQw4w9WgXcQ",
		title: "Never Gonna Give You Up",
		artist: "Rick Astley",
		album: null,
		artworkUrl: null,
		durationMs: null,
		streamUrl: null,
		mbid: null,
		playable: false,
		deepLink: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
	},
	// An import row with no playable match.
	placeholder: {
		id: "youtube:search:Blinding Lights The Weeknd",
		source: "youtube",
		sourceId: "search:Blinding Lights The Weeknd",
		title: "Blinding Lights",
		artist: "The Weeknd",
		album: "After Hours",
		artworkUrl: null,
		durationMs: 200040,
		streamUrl: null,
		mbid: null,
		playable: false,
		deepLink: "https://www.youtube.com/results?search_query=Blinding%20Lights%20The%20Weeknd",
	},
} satisfies Record<string, Track>;

describe("Track: stored track_json", () => {
	it.each(Object.entries(stored))("%s parses back unchanged, id included", (_, t) => {
		expect(trackSchema.parse(t)).toEqual(t);
	});
});

describe("toCanonical", () => {
	it("lifts a track into its metadata plus one source, keeping its id", () => {
		expect(toCanonical(stored.audius)).toEqual({
			id: "audius:ng9rl",
			title: "lofi type beat",
			artist: "bsdu",
			album: null,
			artworkUrl: "https://audius.example/480x480.jpg",
			durationMs: 120000,
			mbid: null,
			sources: [
				{
					provider: "audius",
					sourceId: "ng9rl",
					playback: "native",
					playable: true,
					streamUrl: "https://api.audius.co/v1/tracks/cidstream/x?signature=y",
					deepLink: null,
				},
			],
		});
	});

	it("makes YouTube, import placeholders included, an embed source that keeps its id and deep link", () => {
		for (const t of [stored.youtube, stored.placeholder]) {
			const c = toCanonical(t);
			expect(c.id).toBe(t.id);
			expect(c.sources).toEqual([{ provider: "youtube", sourceId: t.sourceId, playback: "embed", playable: false, streamUrl: null, deepLink: t.deepLink }]);
		}
	});

	it.each(Object.entries(stored))("loses no field of a stored %s track", (_, t) => {
		const {
			sources: [s],
			...meta
		} = toCanonical(t);
		expect({ ...meta, source: s.provider, sourceId: s.sourceId, playable: s.playable, streamUrl: s.streamUrl, deepLink: s.deepLink }).toEqual(t);
	});
});
