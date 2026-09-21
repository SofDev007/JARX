# JARX — Jaiswal Adaptive Response eXperience

Private, single-user music streaming app (Android first, iOS later). One owner, one user. Never published.

## Stack
- backend/  → Cloudflare Workers + Hono (TypeScript), D1 (SQLite) binding `jarx_db`, Vitest with @cloudflare/vitest-pool-workers
- app/      → Flutter (Dart), Riverpod, Dio, just_audio + audio_service, Drift for local cache

## Hard rules
- Music sources: Audius (primary, no key), Jamendo (key: JAMENDO_CLIENT_ID), Internet Archive (no key). YouTube Data API is METADATA ONLY (key: YOUTUBE_API_KEY): results are `playable: false` and open the YouTube app via deep link. Never extract, proxy, or download YouTube or Spotify audio.
- Never use Spotify APIs or scrape Spotify.
- Secrets live only in Worker secrets (`wrangler secret put`) or local `.dev.vars` (gitignored). Never hardcode, log, or commit them.
- Every backend route except GET /health requires `Authorization: Bearer <JARX_TOKEN>`.
- Store a MusicBrainz ID (`mbid`, nullable) on every track. Unused in JARX 1, needed for the JARX 2 recommendation engine.
- Audio streams straight from source CDNs to the device. The backend never proxies audio bytes.

## Normalized track model
Track { id, source: "audius"|"jamendo"|"archive"|"youtube", sourceId, title, artist, album?, artworkUrl?, durationMs?, streamUrl?, mbid?, playable, deepLink? }

## Working method
- Build → verify → fix loop. After every unit of work run the verification commands for that phase. Do not move on while anything is red.
- Verify external API shapes against the live API (curl) and official docs before writing an adapter. Record real sample responses as test fixtures.
- Keep PROGRESS.md at repo root: checklist of the phase's tasks, ticked as they pass verification, plus any open issues.
- Stop and ask me ONLY when: an account/secret/manual action is needed, a step is irreversible, or the same failure persists after 3 genuinely different fix attempts. Otherwise make the sensible call, note it in PROGRESS.md, and continue.
- Commit to git after each verified task with a clear message.