# JARX — Jaiswal Adaptive Response eXperience

Private, single-user music streaming app (Android first, iOS later). One owner, one user. Never published.

## Stack
- backend/  → Cloudflare Workers + Hono (TypeScript), D1 (SQLite) binding `jarx_db`, Vitest with @cloudflare/vitest-pool-workers
- app/      → Flutter (Dart), Riverpod, Dio, just_audio + audio_service, Drift for local cache

## Providers
- Every provider is declared once, in the registry `backend/src/providers.ts` (name, enabled, kind, weight, playback type, adapter). Never hard-code provider lists elsewhere.
- Active target providers: Local, JioSaavn, YouTube Music, YouTube.
- Legacy providers: Audius, Jamendo, Internet Archive. When the provider-retirement phase comes they are disabled (`enabled: false`), never deleted: their adapters, tests, fixtures and provider-specific code stay recoverable and re-enableable.
- Local music is indexed on the device and is never uploaded to the backend.
- JioSaavn has no official public API; JARX uses only jiosaavn.com's own search endpoint, for metadata. Its audio URLs are protected media: never read, decrypt (DES or otherwise), rebuild or proxy them, and never pass its preview clip off as the song. JioSaavn tracks are `playback: embed`, `playable: false`, and open their song page in JioSaavn.
- Playback types: `local` (device file), `native` (JARX streams it), `embed` (plays only in the provider's own player).

## YouTube
- Allowed: YouTube search as a video discovery source (`kind: video`), searched alongside the music providers and shown in its own section, never mixed into music results. Normal YouTube playback/handoff: results are `playable: false` and open the YouTube app (or browser) via their deep link, ads included.
- Not allowed: extracting YouTube protected audio streams, signature/cipher extraction, bypassing or blocking YouTube ads, intercepting YouTube media requests. `/tracks/youtube/.../stream` always answers 422.
- Key: YOUTUBE_API_KEY. `search.list` has its own quota bucket (100 calls/day by default, reset at midnight Pacific Time).

## Spotify
- Spotify playlist metadata/API access may be used for legitimate playlist metadata import.
- Spotify audio extraction, downloading, ripping or playback extraction is NOT allowed.
- Spotify URL import means: Spotify playlist URL → playlist metadata/tracks → JARX SourceResolver → JARX-supported providers → JARX playlist.

## External music websites
- PagalNew, PagalWorld, Mr-Jatt and similar sites are not part of the JARX roadmap. No scraping, audio interception, hotlink bypassing or proxying for them.

## Hard rules
- Secrets live only in Worker secrets (`wrangler secret put`) or local `.dev.vars` (gitignored). Never hardcode, log, or commit them.
- Every backend route except GET /health requires `Authorization: Bearer <JARX_TOKEN>`.
- Store a MusicBrainz ID (`mbid`, nullable) on every track. Unused in JARX 1, needed for the JARX 2 recommendation engine.
- Audio streams straight from source CDNs to the device. The backend never proxies audio bytes.

## Normalized track model
- Track { id, source: <registry provider id>, sourceId, title, artist, album?, artworkUrl?, durationMs?, streamUrl?, mbid?, playable, deepLink? }, stored as D1 `track_json`. `id` is always `<source>:<sourceId>`.
- CanonicalTrack (`backend/src/track.ts`): the metadata plus `sources[]`, one TrackSource { provider, sourceId, playback, playable, streamUrl, deepLink } per provider copy. Search results carry both: the flat Track fields of the best copy, plus `sources`.

## Working method
- Build → verify → fix loop. After every unit of work run the verification commands for that phase. Do not move on while anything is red.
- Verify external API shapes against the live API (curl) and official docs before writing an adapter. Record real sample responses as test fixtures.
- Keep PROGRESS.md at repo root: checklist of the phase's tasks, ticked as they pass verification, plus any open issues.
- Stop and ask me ONLY when: an account/secret/manual action is needed, a step is irreversible, or the same failure persists after 3 genuinely different fix attempts. Otherwise make the sensible call, note it in PROGRESS.md, and continue.
- Commit to git after each verified task with a clear message.