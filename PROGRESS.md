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
- [x] `npm test` (sources, importer, routes, resolver): 83 passing
- [x] `wrangler dev` smoke: /health, 401 without token, /search?q=lofi, cache hit, playlist create→add→reorder→read, stream, import
- [x] `wrangler dev` smoke **with real keys against the live APIs**: Jamendo search + stream, YouTube 422 + deep link, Exportify CSV import (multi-artist, quoted commas, ` - ` title suffixes) and plain-text import
- [x] Deployed to **https://jarx-backend.jarx-backend.workers.dev** (`wrangler deploy --minify --secrets-file .dev.vars`). Verified: `secret list` shows all three, no remote migrations pending, `/health` 200, 401 without/with a wrong token, authenticated `/search` 200 (~3s uncached), `/tracks/jamendo/:id/stream` 200 (flaky, see Open issues)
- [x] `POST /import/playlist?playlistId=` appends to an existing playlist (404s an unknown id before resolving any rows), so the app can split a large import across requests under the Free plan's 50-subrequest cap
- [x] README endpoints section (`backend/README.md`) + `.dev.vars.example`

## Phase 2 — Flutter app (`app/`)

Built against the deployed backend (`https://jarx-backend.jarx-backend.workers.dev`).
Flutter 3.47.5 / Dart 3.13.4. Test device: realme 5 Pro (RMX1971), Android 11 / API 30, arm64-v8a.

### Compatibility: minSdk 29 (Android 10)
- [x] `minSdk = 29` in `android/app/build.gradle.kts`
- [x] Every Android plugin's declared minSdk audited from its real Gradle file, direct and transitive, **before** adding it to `app/` (resolved in a throwaway probe project first):

  | Plugin | minSdk | Pulled in by |
  | --- | --- | --- |
  | just_audio 0.10.6 | 16 | direct |
  | audio_service 0.18.19 | 19 | direct |
  | sqflite_android 2.4.4 | 19 | audio_service → flutter_cache_manager |
  | android_file_picker 2.0.0 | 21 | file_picker 13.1.0 |
  | jni / jni_flutter 1.0.3 | 21 | file_picker, path_provider |
  | audio_session 0.2.4 | 24 | just_audio |
  | url_launcher_android 6.3.33 | 24 | direct |
  | path_provider_android 2.3.1 | inherits app | drift_flutter |

  Highest is 24, and nothing forces a floor above 29. Pure-Dart packages (riverpod, dio, drift) have no Android floor. sqlite3 3.5.2 builds through Dart build hooks against the app's own minSdk.
- [x] Manifest merger at minSdk 29 passed, which is the definitive check covering every transitive AAR (Media3 etc.). The built APK reports `minSdkVersion 29`, `targetSdkVersion 36`, AudioService `foregroundServiceType=mediaPlayback`, and MediaButtonReceiver present
- **Limitation:** API 29 itself cannot be tested on-device, since the only device is API 30 and there is no emulator (virtualization is off in BIOS). API 29 is covered only by build configuration (minSdk 29, manifest merger) and by reading the plugins' source for API branches. Everything else is verified on the API 30 device.

### audio_service against API 29–30 (from its 0.18.19 source, not just the README)
- `startForeground(id, notification)`: the 2-arg form, which on API 29+ takes the type from the manifest's `foregroundServiceType="mediaPlayback"` (the attribute itself arrived in API 29).
- Notification channel: created by the plugin under `@RequiresApi(O)` (26+), so it runs on 29–30.
- **Collapsed-notification buttons are an API 29–32 specific:** the plugin calls `setShowActionsInCompactView` only when `SDK_INT < 33`, so `androidCompactActionIndices: [0, 1, 2]` is set explicitly. Android 13+ ignores it, so a newer test phone would never have caught this.
- `POST_NOTIFICATIONS` is not declared: it doesn't exist below API 33, and media-session notifications are exempt from it on 33+.
- `FOREGROUND_SERVICE_MEDIA_PLAYBACK` is declared: it is unknown to (and ignored by) Android 10–13, and required on 14+ because targetSdk ≥ 34.
- `androidStopForegroundOnPause: false`: the background-FGS-restart restriction it avoids starts at Android 12. It isn't needed on 10–11, but costs nothing there and prevents `ForegroundServiceStartNotAllowedException` on newer phones.
- url_launcher: `launchUrl()` calls `startActivity()` directly. Only `canLaunchUrl()` (unused) is affected by Android 11's package visibility, so no `<queries>` entry is needed. `externalNonBrowserApplication` (which forces the YouTube app) only applies its flag on API 30+; the code falls back to `externalApplication`.
- `INTERNET` added to the main manifest. Flutter's template only puts it in the debug manifest, so a release build would have had no network.

### Foundation
- [x] `flutter create` in `app/`, Android only, package id `com.jaiswal.jarx`
- [x] Riverpod + Dio + just_audio + audio_service + Drift wired; `flutter analyze` clean
- [x] Base URL defaults to the deployed Worker; `JARX_TOKEN` comes from gitignored `app/.env` via `--dart-define-from-file`, and the app shows a clear screen if it was built without one
- [x] `Track` model mirrors the backend field for field, including `mbid` and `playable` (round-trip test)
- [x] Dio sends the bearer header and maps `{ error: { code, message } }` to `ApiException` (tests)

### Search
- [x] Debounced search, artwork, source and duration per row
- [x] **"Found on YouTube" is a first-class answer state** with its own banner, distinct from empty and error. It also has a "Best match is on YouTube" variant for when the playable rows below are likely covers or remixes (widget tests for all five states)
- [x] YouTube rows are visibly distinct everywhere they appear (dimmed art + YouTube badge, "YouTube · not streamable", an Open button), and tapping one opens the YouTube app instead of the player
- [ ] Verified on device

### Playback
- [x] just_audio + audio_service handler: queue, next/previous, seek, notification controls
- [x] Plays the URL a track already carries and fetches a fresh one from `/stream` only if the player fails. This keeps playback off Jamendo's flaky `id=` lookup (see Open issues)
- [x] Resume: queue and position saved (every 15s while playing, and on pause/stop/track change) and restored paused at launch
- [ ] Verified on device: background playback, lock screen, notification buttons on API 30, headset unplug pauses

### Library
- [x] Playlists: list, create, rename, delete, add (from any track's ⋮), swipe to remove, drag to reorder (optimistic, then reconciled with the server)
- [x] Favorites and recently played; each play is posted to history
- [x] Drift cache: the last good copy of each library response is served when offline (tested against in-memory SQLite)
- [ ] Verified on device

### Import
- [x] Pick an Exportify CSV or a text file. The app sends it in chunks of 20 rows (≈40 subrequests, under the Free plan's 50), keeping the CSV header on each chunk, 1s apart, into one playlist via `?playlistId=`. Progress is shown, then the list of unmatched rows
- [ ] Verified on device against the deployed backend

### Verification for this phase
- [x] `flutter analyze` clean, `flutter test` green (15 tests: API client, import chunking, offline cache, 6 search-state widget tests)
- [x] Debug APK builds with minSdk 29 (`aapt2 dump badging` verified)
- [ ] Release APK builds
- [ ] Installed and run on the RMX1971 against the deployed backend

## Phase 3: Architecture foundation (backend)

Scope: a provider registry and the multi-source track model only. No new providers, no disabling, no UI.

- [x] Single provider registry, `backend/src/providers.ts`: id, display name, `enabled`, `kind` (audio | video), `weight`, playback type (local | native | embed), adapter, optional deep-link builder. `SOURCES` and the `Source` type derive from it.
- [x] The resolver and routes read only the registry. Gone: `WEIGHT`, `PLAYABLE_SOURCES`, `ADAPTERS`, the `["youtube"]` fallback list, import's `["audius","jamendo"]` and the route's `source === "youtube"`. Search order, weights, fallback and import sources are unchanged.
- [x] `enabled` flag: a disabled provider is never searched or matched for imports. Search-cache keys include the set of enabled providers.
- [x] Track model moved to `backend/src/track.ts`, with the schema unchanged. Added `TrackSource` / `CanonicalTrack` (metadata + `sources[]`) and `toCanonical()`, a lossless conversion. Not stored or served yet, so there is no D1 migration and no API change.
- [x] YouTube stream route still answers 422 with the deep link (same body), now because its playback type is `embed`.
- [x] `npx tsc --noEmit` clean; `npm test` 109 passing (83 existing, unmodified; 26 new in `providers.test.ts`, `track.test.ts`)
- [x] `flutter analyze` clean; `flutter test` 16 passing (1 new: stored placeholders parse, unknown fields ignored). No app code changed.

## Decisions made without asking

- **Phase 2 plan**: none existed, so the draft checklist in this file was used, per "proceed as specified in the plan".
- **Drift without codegen**: the cache is one key-value table (path → last good JSON), so it uses Drift's raw-SQL API. That means no drift_dev/build_runner and no generated files.
- **Play the URL a track already has; refetch only on failure.** This replaces the draft's "fetch per track at play time, never cache". Verified: Jamendo URLs recorded 2 days earlier still serve audio. It also keeps playback off Jamendo's flaky `/stream` lookup.
- **Import chunk size 20 rows**, not the theoretical 25, to leave headroom for Audius host failovers inside the 50-subrequest cap. Chunks go 1s apart per your Free-plan decision. Batching into one playlist required the backend's new `?playlistId=`.
- **"Best match is on YouTube" banner variant**: shown when YouTube tops mixed results. The backend only queries YouTube when no playable row matched confidently, so in that case the playable rows are usually covers or remixes.
- **Search asks for 25 results** (backend default 20, max 50).
- **Audius hosts**: `GET https://api.audius.co` now returns only `["https://api.audius.co"]`, so the adapter skips that lookup and tries `api.audius.co` then `discoveryprovider.audius.co` (verified live to serve the same `/v1` API). Retries only on network errors/5xx; 4xx is a real answer.
- **Archive query**: full-text relevance put auto-uploaded podcasts with only `private` MP3s first (5/5 unplayable for "lofi"). Now searches `title`/`creator`, requires `format:"VBR MP3"`, sorts by downloads (5/5 playable across test queries). Files with `private: "true"` are filtered out.
- **Import** queries only Audius + Jamendo: archive's 0.7 weight can never reach the 0.75 match bar, and YouTube (100 searches/day) would be exhausted by a single playlist. Unmatched rows are stored as `playable:false` tracks with source `youtube` and a deep link to a YouTube *search* (`sourceId: "search:<query>"`); this costs no quota.
- **Import artist check**: a row only matches a candidate whose artist also matches. Seen live: "Blinding Lights - The Weeknd" matched a 34s "[COVER]" by DJ-M.
- **YouTube weight** 0.9 (spec only weighted the three playable sources).
- **Compatibility date** lowered from 2026-09-16 to 2026-08-22: the workerd bundled with `@cloudflare/vitest-pool-workers@0.22` supports up to 2026-08-22, and tests and production should run the same runtime behavior.
- **`remote: true` removed** from the D1 binding so `wrangler dev` and tests use a local database, never production. Static `public/` assets removed so no path bypasses auth.
- `Track.id` is always derived as `<source>:<sourceId>` (client-supplied ids are ignored); optional fields are stored as explicit `null`.
- **Registry holds only implemented providers.** local/jiosaavn/ytmusic get entries when they are built: the Track schema's source enum derives from the registry, and registering them early would make the backend accept those sources in stored tracks.
- **Disabled ≠ gone.** `enabled: false` removes a provider from search and import matching only. Its stored tracks still validate and `/tracks/:source/:id/stream` still resolves them, so the library keeps playing.
- **Import eligibility is derived, not listed:** enabled `audio` providers whose weight can reach `HIT_SCORE` (0.75). That is exactly Audius + Jamendo today; archive's 0.7 never could.
- **Search-cache key now includes the enabled set**, so flipping a flag never serves a stale cached answer. One-off cost: entries cached before the next deploy are missed once. Weights and kinds are not part of the key; a change to those still takes up to 24h to reach cached queries, as before.
- **Wire format and D1 untouched in Phase 3:** `CanonicalTrack` exists as a type plus `toCanonical()`, not yet in responses, so the app needed no code change.

## Open issues

- Archive is slow from India (0.5–2.2s for search alone, 4–10s with item metadata), so it often returns partial or no results within 2.5s. Revisit after measuring the deployed Worker; Smart Placement is an option.
- Staying on the **Free** plan by decision. ~2 subrequests per row against a 50-per-request cap means imports past ~25 rows must be split client-side; the app will batch them with a ~1s gap between rows. Import is capped at 500 rows server-side.
- **Jamendo's `search=` is flaky**: the identical URL returns 5 results or 0 at random, always HTTP 200 with `status: "success"` (measured 4/6 empty in one run, 2/8 in another). `namesearch=` flakes too and ignores the artist, so it is not an upgrade. Left unfixed by decision: the resolver already tolerates an empty source, and a retry would double Jamendo subrequests per imported row against the Free plan's 50-subrequest cap. `gather()` now logs `jamendo returned 0 results ... while another source had hits`, so a rising flake rate is visible in `wrangler tail`.
- **Jamendo's flake also hits the `id=` lookup behind `/stream`** (1/4 direct calls answered; 2/4 via the deployed Worker), so `/tracks/jamendo/:id/stream` 404s at random. Not fixed in the backend (decision stands). The app avoids depending on it: Jamendo stream URLs do not expire (URLs recorded 2026-09-23 still served `206 audio/mpeg` on 2026-09-25), so the app plays `track.streamUrl` directly and only calls `/stream` when the player errors.
- **`mix` is not a version marker.** Live on the deployed Worker, `blinding lights the weeknd` tops out at "The Weeknd - Blinding Lights (DJ Luciano Velocity Mix)" by Luciano Deejay at 0.85, which blocks the YouTube fallback. Adding `mix` would also demote "(Original Mix)" (the real song in Beatport-style naming) and lofi DJ mixes, a core Audius use case. **Needs a decision.**
- **Build environment (this PC).** Its only internet is the phone's USB tethering (`Remote NDIS based Internet Sharing Device`). Brief DNS outages there broke three Gradle runs (`No such host is known`), and a USB re-enumeration reset the phone's adb authorization. Fixed on the machine, outside the repo: `~/.gradle/gradle.properties` sets `org.gradle.internal.repository.max.tentatives=8` and `initial.backoff=2000` (Gradle 9.3.1's names, confirmed in its jars), so retries outlast the outages. The SDK's `cmdline-tools/latest` is the new Android CLI, whose `sdkmanager.bat` shim crashes (`0xC0000409`) when AGP asks it for the NDK. NDK 28.2.13676358 (Flutter 3.47.5's pin) and `platforms/android-36` were installed with `android sdk install` instead.
