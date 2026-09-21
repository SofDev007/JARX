# JARX — Progress

## Phase 1 — Backend (`backend/`)

- [x] D1 schema via wrangler migrations (`0001_init.sql`), applied locally
- [ ] D1 schema applied to remote (done right before first deploy)
- [x] Bearer auth on every route except `GET /health`, constant-time (SHA-256 digests + `crypto.subtle.timingSafeEqual`), fails closed if `JARX_TOKEN` is unset
- [x] Audius adapter (search, fresh stream URL, host failover), tested against recorded live responses
- [x] Internet Archive adapter (advancedsearch → item files → public MP3), tested against recorded live responses
- [ ] Jamendo adapter: code done, **real fixture pending** (needs `JAMENDO_CLIENT_ID`)
- [ ] YouTube adapter: code done, **real fixture pending** (needs `YOUTUBE_API_KEY`); resolver unit tests import it
- [x] SourceResolver: parallel `Promise.allSettled`, 2.5s per-source `AbortSignal`, fuzzy score × weight, dedupe, drop < 0.5, YouTube only on miss, 24h D1 cache
- [x] Routes: health, search, stream, playlists CRUD + add/remove/reorder, favorites, recently-played (last 200), import
- [x] zod validation, `{ error: { code, message, details? } }` error shape, no CORS
- [x] `npx tsc --noEmit` clean
- [x] `npm test` (sources, importer, routes): 49 passing; resolver suite waiting on the YouTube fixture
- [x] `wrangler dev` smoke: /health, 401 without token, /search?q=lofi, cache hit, playlist create→add→reorder→read, stream, import
- [ ] `wrangler deploy` + curl deployed /health and authenticated /search
- [ ] README endpoints section

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
- Mainstream songs: Audius covers/remixes titled "Artist - Song (Remix)" score ≥ 0.75, so `/search` treats them as hits and doesn't fall back to YouTube.
- Large imports need Workers Paid: ~2 subrequests per row (Free plan allows 50 per request; Paid allows 10,000). Import is capped at 500 rows.
