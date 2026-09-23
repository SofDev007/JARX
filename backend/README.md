# JARX backend

Cloudflare Worker (Hono + D1) behind a single bearer token. Audio never passes
through the Worker: `/search` returns the source CDN's URL and the device
streams from it directly.

## Run it

```sh
npm install
cp .dev.vars.example .dev.vars   # then fill in the three secrets
npx wrangler d1 migrations apply jarx-db --local
npm run dev
```

Verification, all of which must be green before moving on:

```sh
npm run typecheck
npm test
```

Other scripts: `npm run deploy` (`wrangler deploy --minify`) and `npm run cf-typegen`,
which regenerates the `CloudflareBindings` interface after a binding or secret changes.

## Secrets

| Name | Where to get it |
| --- | --- |
| `JARX_TOKEN` | You pick it. Any long random string; the app sends it as the bearer token. |
| `JAMENDO_CLIENT_ID` | developer.jamendo.com → register an app |
| `YOUTUBE_API_KEY` | Google Cloud Console → enable *YouTube Data API v3* → API key |

Local: `backend/.dev.vars` (gitignored). Deployed: `npx wrangler secret put <NAME>`.

## Auth

Every route except `GET /health` needs `Authorization: Bearer $JARX_TOKEN`.
A missing or wrong token gets `401` with `WWW-Authenticate: Bearer`. If
`JARX_TOKEN` is unset the Worker fails closed and rejects everything.

Errors are always `{ "error": { "code", "message", "details"? } }`.

## Endpoints

### Search and streams

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/health` | `{ status: "ok" }`. The only unauthenticated route. |
| `GET` | `/search?q=&limit=` | `limit` 1–50, default 20. Returns `{ query, results, cached }`; each result is a Track plus `score`. Cached in D1 for 24h per normalized query. |
| `GET` | `/tracks/:source/:id/stream` | `{ url }` — a fresh CDN URL. `:id` may contain slashes (archive ids are `item/file.mp3`). YouTube returns `422 not_playable` with the deep link in `details`. |

`/search` queries Audius, Jamendo and Internet Archive in parallel (2.5s budget
each), scores every candidate on fuzzy title+artist similarity × a per-source
weight, dedupes and drops anything under 0.5. YouTube is only queried when
nothing playable scores as a confident hit, and its results are always
`playable: false` with a `deepLink` — metadata only, never audio.

### Playlists

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/playlists` | `{ playlists: [{ id, name, createdAt, updatedAt, trackCount }] }` |
| `POST` | `/playlists` | `{ name }` → the created playlist |
| `GET` | `/playlists/:id` | `{ id, name, createdAt, updatedAt, tracks: [{ position, addedAt, track }] }` |
| `PATCH` | `/playlists/:id` | `{ name }` — rename |
| `DELETE` | `/playlists/:id` | `204` |
| `POST` | `/playlists/:id/tracks` | `{ tracks: [Track] }`, 1–500, appended |
| `DELETE` | `/playlists/:id/tracks/:position` | Removes one entry and closes the gap |
| `POST` | `/playlists/:id/reorder` | `{ from, to }` |

### Favorites and history

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/favorites` | `{ items: [{ track, addedAt }] }`, newest first |
| `POST` | `/favorites` | `{ track }` → `201`. Re-favoriting refreshes the track but keeps the original `addedAt`. |
| `DELETE` | `/favorites/:key` | `:key` is `Track.id`, e.g. `audius:95wro` |
| `GET` | `/recently-played?limit=` | `{ items: [{ track, playedAt }] }`, default 50 |
| `POST` | `/recently-played` | `{ track }` → `201`. Trimmed to the last 200. |

### Import

`POST /import/playlist?name=` with the file as the raw body (max 1MB, 500 rows).
Two formats, detected automatically:

- **Exportify CSV** — any export with a `Track Name` column. Also reads
  `Artist Name(s)` (first artist wins), `Album Name` and `Track Duration (ms)`.
- **Plain text** — one `title - artist` per line, split at the last separator.

Each row is resolved against Audius and Jamendo only; a row matches solely when
the artist matches too, which keeps covers and remixes out. Unmatched rows are
still added, as `playable: false` tracks whose `deepLink` opens a YouTube
*search* — that costs no API quota.

Returns `{ playlistId, name, matched, unmatched: [{ line, title, artist, reason }], malformed }`.

## Track model

```ts
Track {
  id            // always "<source>:<sourceId>"; client-supplied ids are ignored
  source        // "audius" | "jamendo" | "archive" | "youtube"
  sourceId
  title
  artist
  album         // nullable
  artworkUrl    // nullable
  durationMs    // nullable
  streamUrl     // nullable
  mbid          // nullable; unused in JARX 1, reserved for the JARX 2 recommender
  playable      // false for every YouTube result
  deepLink      // nullable; set for YouTube
}
```
