export type ImportRow = { line: number; title: string; artist: string; album: string | null; durationMs: number | null };
export type MalformedRow = { line: number; raw: string; reason: string };

/** One RFC 4180 record. Returns null on an unterminated quote. */
// ponytail: line-based, so quoted fields can't contain newlines (Exportify never emits them).
export function parseCsvLine(line: string): string[] | null {
	const fields: string[] = [];
	let field = "";
	let quoted = false;
	for (let i = 0; i < line.length; i++) {
		const ch = line[i];
		if (quoted) {
			if (ch !== '"') field += ch;
			else if (line[i + 1] === '"') (field += '"'), i++;
			else quoted = false;
		} else if (ch === '"') quoted = true;
		else if (ch === ",") fields.push(field), (field = "");
		else field += ch;
	}
	if (quoted) return null;
	fields.push(field);
	return fields;
}

// Exportify joins artists with "," (escaping commas inside names as "\,"); the first is the primary artist.
const firstArtist = (s = "") => s.split(/(?<!\\),/)[0].replace(/\\,/g, ",").trim();

/**
 * Exportify CSV (detected by a "Track Name" header column) or plain text lines
 * "title - artist" (split at the last " - "; a line without one is title-only).
 */
export function parseImport(text: string): { rows: ImportRow[]; malformed: MalformedRow[] } {
	const lines = text.replace(/^﻿/, "").split(/\r?\n/);
	const rows: ImportRow[] = [];
	const malformed: MalformedRow[] = [];
	const headerAt = lines.findIndex((l) => l.trim());
	const header = headerAt >= 0 ? (parseCsvLine(lines[headerAt]) ?? []).map((h) => h.trim()) : [];
	const col = (re: RegExp) => header.findIndex((h) => re.test(h));
	const titleCol = col(/^track name$/i);

	if (titleCol >= 0) {
		const artistCol = col(/^artist name\(s\)$/i);
		const albumCol = col(/^album name$/i);
		const durationCol = col(/duration \(ms\)$/i); // "Track Duration (ms)" now, "Duration (ms)" in older exports
		lines.forEach((raw, i) => {
			if (i <= headerAt || !raw.trim()) return;
			const f = parseCsvLine(raw);
			const title = f?.[titleCol]?.trim();
			if (!f || !title) return void malformed.push({ line: i + 1, raw, reason: f ? "missing track name" : "unterminated quote" });
			const durationMs = Number.parseInt(f[durationCol] ?? "", 10);
			rows.push({
				line: i + 1,
				title,
				artist: firstArtist(f[artistCol]),
				album: f[albumCol]?.trim() || null,
				durationMs: Number.isFinite(durationMs) ? durationMs : null,
			});
		});
	} else {
		lines.forEach((raw, i) => {
			const line = raw.trim();
			if (!line) return;
			const m = line.match(/^(.*)\s*[-–—]\s+(.+)$/); // greedy: splits at the last separator
			const title = (m ? m[1] : line).trim();
			if (!title) return void malformed.push({ line: i + 1, raw, reason: "missing title" });
			rows.push({ line: i + 1, title, artist: m ? m[2].trim() : "", album: null, durationMs: null });
		});
	}
	return { rows, malformed };
}

/** Search query for a row: drops "(feat. …)", "[…]" and Spotify's " - Remastered 2011"-style suffixes. */
export function rowQuery(row: ImportRow): string {
	const title = row.title.replace(/\s*[([].*?[)\]]/g, "").replace(/\s+-\s+.*$/, "").trim() || row.title;
	return `${title} ${row.artist}`.trim();
}
