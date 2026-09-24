# JARX — Progress

## Phase 1 — Backend (`backend/`)

- [x] D1 schema via wrangler migrations (`0001_init.sql`), applied locally
- [x] D1 schema applied to remote (`d1 migrations apply jarx-db --remote`; verified: favorite, playlist, playlist_track, recently_played, search_cache)
- [x] Bearer auth on every route except `GET /health`, constant-time (SHA-256 digests + `crypto.subtle.timingSafeEqual`), fails closed if `JARX_TOKEN` is unset
- [x] Audius adapter (search, fresh stream URL, host failover), tested against recorded live responses
- [x] Internet Archive adapter (advancedsearch → item files → public MP3), tested against recorded live responses
- [x] Jamendo adapter, tested against recorded live responses (search + track-by-id)
- [x] YouTube adapter (metadata only), tested against a recorded live response
- [x] Cover/remix demotion in `rank()`: a candidate whose **title or artist** carries a version marker (cover|remix(ed)|flip|bootleg|mashup|karaoke|instrumental|tribute|nightcore|sped up|slowed|reverb|8d|made famous by|originally performed by) scores ×0.7, unless the query itself asks for that same marker. Verified live: `blinding lights the weeknd` now falls back to YouTube instead of returning an Audius "[COVER]" at 0.917. `live` is deliberately not a marker (archive.org is mostly legitimate live recordings).
- [x] SourceResolver: parallel `Promise.allSettled`, 2.5s per-source `AbortSignal`, fuzzy score × weight, dedupe, drop < 0.5, YouTube only on miss, 24h D1 cache
- [x] Routes: health, search, stream, playlists CRUD + add/remove/reorder, favorites, recently-played (last 200), import
- [x] zod validation, `{ error: { code, message, details? } }` error shape, no CORS
- [x] `npx tsc --noEmit` clean
- [x] `npm test` (sources, importer, routes, resolver): 81 passing
- [x] `wrangler dev` smoke: /health, 401 without token, /search?q=lofi, cache hit, playlist create→add→reorder→read, stream, import
- [x] `wrangler dev` smoke **with real keys against the live APIs**: Jamendo search + stream, YouTube 422 + deep link, Exportify CSV import (multi-artist, quoted commas, ` - ` title suffixes) and plain-text import
- [x] Deployed to **https://jarx-backend.jarx-backend.workers.dev** (`wrangler deploy --minify --secrets-file .dev.vars`). Verified: `secret list` shows all three, no remote migrations pending, `/health` 200, 401 without/with a wrong token, authenticated `/search` 200 (~3s uncached), `/tracks/jamendo/:id/stream` 200 (flaky, see Open issues)
- [x] README endpoints section (`backend/README.md`) + `.dev.vars.example`

## Phase 2 — Flutter app (`app/`) — DRAFT, not started

No plan for this phase existed, so this checklist is my proposal. Say what to
cut or add. Nothing here is built yet; Flutter is not installed on this machine.

### Blocked on you
- [ ] Install Flutter SDK + Android SDK/platform-tools, `flutter doctor` clean
- [ ] Cloudflare: verify account email, register a workers.dev subdomain, then deploy
- [ ] Confirm this checklist

### Foundation
- [ ] `flutter create` in `app/`, Android only for now, package id `com.jaiswal.jarx`
- [ ] Riverpod + Dio + just_audio + audio_service + Drift wired, `flutter analyze` clean
- [ ] Base URL and `JARX_TOKEN` via `--dart-define`, never committed; Dio interceptor adds the bearer header and maps `{ error: { code, message } }` to a typed failure
- [ ] `Track` model mirroring the backend exactly, including `mbid` and `playable`

### Search
- [ ] Search screen: debounced query, results list, artwork, source badge
- [ ] **"Found, but only on YouTube" is a first-class result state**, not an error or an empty state: when every row is `playable: false`, the screen says the track was found and offers "Open in YouTube" per row. The cover/remix penalty makes this a normal outcome for mainstream songs, so it must not read as a failure.
- [ ] Non-playable rows are visibly distinct everywhere they appear (search, playlist, history) and tapping one opens the deep link rather than the player

### Playback
- [ ] just_audio + audio_service: background playback, lock-screen/notification controls
- [ ] Stream URLs fetched per track at play time from `/tracks/:source/:id/stream` (they expire; never cache them)
- [ ] Queue, next/previous, seek, resume position

### Library
- [ ] Playlists: list, create, rename, delete, add/remove/reorder
- [ ] Favorites and recently-played, posting to the backend on play
- [ ] Drift cache of playlists/favorites/track metadata for offline browsing (metadata only — audio is never downloaded)

### Import
- [ ] Pick an Exportify CSV or a text file and POST to `/import/playlist`
- [ ] **Batch rows client-side (~25 per request, ~1s between rows)** to stay under the Free plan's 50-subrequest cap; show progress and list the unmatched rows afterwards

### Verification for this phase
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Widget tests for the search states, including the YouTube-only state
- [ ] Manual run on a real Android device against the **deployed** backend

## Decisions made without asking

- **Audius hosts**: `GET https://api.audius.co` now returns only `["https://api.audius.co"]`, so the adapter skips that lookup and tries `api.audius.co` then `discoveryprovider.audius.co` (verified live to serve the same `/v1` API). Retries only on network errors/5xx; 4xx is a real answer.
- **Archive query**: full-text relevance put auto-uploaded podcasts with only `private` MP3s first (5/5 unplayable for "lofi"). Now searches `title`/`creator`, requires `format:"VBR MP3"`, sorts by downloads (5/5 playable across test queries). Files with `private: "true"` are filtered out.
- **Import** queries only Audius + Jamendo: archive's 0.7 weight can never reach the 0.75 match bar, and YouTube (100 searches/day) would be exhausted by a single playlist. Unmatched rows are stored as `playable:false` tracks with source `youtube` and a deep link to a YouTube *search* (`sourceId: "search:<query>"`); this costs no quota.
- **Import artist check**: a row only matches a candidate whose artist also matches. Seen live: "Blinding Lights - The Weeknd" matched a 34s "[COVER]" by DJ-M.
- **YouTube weight** 0.9 (spec only weighted the three playable sources).
- **Compatibility date** lowered from 2026-09-16 to 2026-08-22: the workerd bundled with `@cloudflare/vitest-pool-workers@0.22` supports up to 2026-08-22, and tests and production should run the same runtime behavior.
- **`remote: true` removed** from the D1 binding so `wrangler dev` and tests use a local database, never production. Static `public/` assets removed so no path bypasses auth.
- `Track.id` is always derived as `<source>:<sourceId>` (client-supplied ids are ignored); optional fields are stored as explicit `null`.

## Open issues

- Archive is slow from India (0.5–2.2s for search alone, 4–10s with item metadata), so it often returns partial or no results within 2.5s. Revisit after measuring the deployed Worker; Smart Placement is an option.
- Staying on the **Free** plan by decision. ~2 subrequests per row against a 50-per-request cap means imports past ~25 rows must be split client-side; the app will batch them with a ~1s gap between rows. Import is capped at 500 rows server-side.
- **Jamendo's `search=` is flaky**: the identical URL returns 5 results or 0 at random, always HTTP 200 with `status: "success"` (measured 4/6 empty in one run, 2/8 in another). `namesearch=` flakes too and ignores the artist, so it is not an upgrade. Left unfixed by decision: the resolver already tolerates an empty source, and a retry would double Jamendo subrequests per imported row against the Free plan's 50-subrequest cap. `gather()` now logs `jamendo returned 0 results ... while another source had hits`, so a rising flake rate is visible in `wrangler tail`.
- **Jamendo's flake also hits the `id=` lookup behind `/stream`** (1/4 direct calls answered; 2/4 via the deployed Worker), so `/tracks/jamendo/:id/stream` 404s at random. Not fixed in the backend (decision stands). The app avoids depending on it: Jamendo stream URLs do not expire (URLs recorded 2026-09-23 still served `206 audio/mpeg` on 2026-09-25), so the app plays `track.streamUrl` directly and only calls `/stream` when the player errors.
- **`mix` is not a version marker.** Live on the deployed Worker, `blinding lights the weeknd` tops out at "The Weeknd - Blinding Lights (DJ Luciano Velocity Mix)" by Luciano Deejay at 0.85, which blocks the YouTube fallback. Adding `mix` would also demote "(Original Mix)" (the real song in Beatport-style naming) and lofi DJ mixes, a core Audius use case. **Needs a decision.**
