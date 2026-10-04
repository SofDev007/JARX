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
| `GET` | `/search?q=&limit=` | `limit` 1–50, default 20, per section. Returns `{ query, music, videos, videoError, cached, results }`. Each result is a Track (its best copy) plus `score` and `sources`. Cached in D1 for 24h per normalized query. |
| `GET` | `/tracks/:source/:id/stream` | `{ url }` — a fresh CDN URL. `:id` may contain slashes (archive ids are `item/file.mp3`). YouTube returns `422 not_playable` with the deep link in `details`; JioSaavn returns `422 not_playable` too (its tracks carry their own `deepLink`). |

`/search` queries the enabled music (`audio`) providers and YouTube (`video`) in
parallel, 2.5s budget each. Every candidate scores on fuzzy title+artist
similarity × a per-source weight, and anything under 0.5 is dropped. Music and
videos are ranked separately and returned apart, so a video never lands in `music`:

- `music`: songs from JioSaavn, Audius, Jamendo and Internet Archive. Copies of the same
  song (same normalized title + artist) merge into one result, with every copy listed in
  `sources`. The flat fields are the lead copy's: one JARX can play beats one it can't,
  then the best score wins.
  JioSaavn rows are metadata only (`playable: false`, `deepLink` to the song page on
  jiosaavn.com) because its audio is protected media JARX never touches; they open JioSaavn.
- `videos`: YouTube, metadata only. Always `playable: false` with a `deepLink` to
  `https://www.youtube.com/watch?v=<id>`; never audio.
- `videoError`: `null`, `"quota_exceeded"` (YouTube answered 403 `quotaExceeded`) or
  `"unavailable"` (any other YouTube failure). Music still answers either way, and a
  search whose videos failed is not cached, so they reappear once YouTube answers again.
- `results`: transitional, music then videos, for app builds from before the split. Remove
  once none are installed.

Quota: `search.list` has its own bucket of 100 calls/day (Google's default; resets at
midnight Pacific Time), and every uncached search spends one. The 24h cache makes
repeat searches free.

Every provider is declared once, in `src/providers.ts`: display name, `enabled`,
`kind` (`audio` results go to `music`, `video` results to `videos`), `weight`,
playback type (`local` | `native` | `embed`) and adapter. Search, import matching,
the stream route and the Track schema all read from it. A disabled provider is
never searched or matched against, but its stored tracks stay valid and still
resolve streams.

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

Pass `playlistId` instead of `name` to **append** to an existing playlist. Each row costs ~2
subrequests and the Free plan allows 50 per request, so the app splits big imports into
chunks and sends each one with the `playlistId` the first chunk returned.

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

`src/track.ts` also defines the coming multi-source shape, `CanonicalTrack`: the
metadata plus `sources[]`, each with its provider, `sourceId`, playback type,
`playable`, `streamUrl` and `deepLink`. Nothing stores or serves it yet.
`toCanonical()` lifts a stored Track into it without losing a field, keeping
`id` as `<source>:<sourceId>`.
