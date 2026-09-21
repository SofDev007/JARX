import { describe, expect, it } from "vitest";
import { parseCsvLine, parseImport, rowQuery } from "../src/importer";

const HEADER =
	'"Track URI","Track Name","Artist URI(s)","Artist Name(s)","Album URI","Album Name","Album Artist URI(s)","Album Artist Name(s)","Album Release Date","Album Image URL","Disc Number","Track Number","Track Duration (ms)","Track Preview URL","Explicit?","Popularity","ISRC","Added By","Added At"';
const row = (name: string, artists: string, album = "Album", ms = "200040") =>
	`"spotify:track:x","${name}","spotify:artist:y","${artists}","spotify:album:z","${album}","spotify:artist:y","${artists}","2020-03-20","https://i.scdn.co/image/x","1","9","${ms}","","false","90","USUG11904206","spotify:user:me","2024-01-01T00:00:00Z"`;

describe("parseCsvLine", () => {
	it("handles quotes, embedded commas and escaped quotes", () => {
		expect(parseCsvLine('a,"b, c","say ""hi""",')).toEqual(["a", "b, c", 'say "hi"', ""]);
	});
	it("returns null on an unterminated quote", () => {
		expect(parseCsvLine('a,"b')).toBeNull();
	});
});

describe("parseImport: Exportify CSV", () => {
	it("reads title, primary artist, album and duration", () => {
		const csv = [HEADER, row("Blinding Lights", "The Weeknd", "After Hours"), row("Get Lucky", "Daft Punk,Pharrell Williams,Nile Rodgers")].join("\n");
		expect(parseImport(csv)).toEqual({
			rows: [
				{ line: 2, title: "Blinding Lights", artist: "The Weeknd", album: "After Hours", durationMs: 200040 },
				{ line: 3, title: "Get Lucky", artist: "Daft Punk", album: "Album", durationMs: 200040 },
			],
			malformed: [],
		});
	});

	it("handles BOM, CRLF, blank lines, commas/quotes in names and escaped commas in artists", () => {
		const csv = "﻿" + [HEADER, row('Hello, ""World""', "Tyler\\, The Creator,Kali Uchis"), "", row("Song", "Artist")].join("\r\n") + "\r\n";
		const { rows, malformed } = parseImport(csv);
		expect(malformed).toEqual([]);
		expect(rows.map((r) => [r.line, r.title, r.artist])).toEqual([
			[2, 'Hello, "World"', "Tyler, The Creator"],
			[4, "Song", "Artist"],
		]);
	});

	it("accepts the older Exportify header layout", () => {
		const csv = '"Spotify ID","Artist IDs","Track Name","Album Name","Artist Name(s)","Release Date","Duration (ms)"\n"id","aid","Halo","I Am... Sasha Fierce","Beyoncé","2008","261640"';
		expect(parseImport(csv).rows).toEqual([{ line: 2, title: "Halo", artist: "Beyoncé", album: "I Am... Sasha Fierce", durationMs: 261640 }]);
	});

	it("reports malformed rows and keeps going", () => {
		const csv = [HEADER, row("Good", "Artist"), '"spotify:track:x","Unclosed, The Weeknd', row("", "No Title"), row("Also Good", "Artist", "A", "not-a-number")].join("\n");
		const { rows, malformed } = parseImport(csv);
		expect(rows.map((r) => [r.line, r.title, r.durationMs])).toEqual([
			[2, "Good", 200040],
			[5, "Also Good", null],
		]);
		expect(malformed.map((m) => [m.line, m.reason])).toEqual([
			[3, "unterminated quote"],
			[4, "missing track name"],
		]);
	});
});

describe("parseImport: text lines", () => {
	it('splits "title - artist" at the last separator', () => {
		const text = ["Blinding Lights - The Weeknd", "", "Empire State of Mind - Jay-Z", "Something - Remastered 2009 - The Beatles", "Levitating – Dua Lipa", "  Bohemian Rhapsody  ", " - Queen"].join("\n");
		const { rows, malformed } = parseImport(text);
		expect(rows.map((r) => [r.line, r.title, r.artist])).toEqual([
			[1, "Blinding Lights", "The Weeknd"],
			[3, "Empire State of Mind", "Jay-Z"],
			[4, "Something - Remastered 2009", "The Beatles"],
			[5, "Levitating", "Dua Lipa"],
			[6, "Bohemian Rhapsody", ""], // no separator: title-only
		]);
		expect(malformed).toEqual([{ line: 7, raw: " - Queen", reason: "missing title" }]);
	});

	it("returns nothing for empty input", () => {
		expect(parseImport(" \n\n")).toEqual({ rows: [], malformed: [] });
	});
});

describe("rowQuery", () => {
	const q = (title: string, artist = "A") => rowQuery({ line: 1, title, artist, album: null, durationMs: null });
	it("drops featuring credits and version suffixes", () => {
		expect(q("Here Comes The Sun - Remastered 2019", "The Beatles")).toBe("Here Comes The Sun The Beatles");
		expect(q("Stay (feat. Justin Bieber)", "The Kid LAROI")).toBe("Stay The Kid LAROI");
		expect(q("Song [Live]")).toBe("Song A");
	});
	it("falls back to the raw title if cleaning empties it", () => {
		expect(q("(Intro)")).toBe("(Intro) A");
	});
});
