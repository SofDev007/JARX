# JARX app

Flutter client for the JARX backend. Android only for now, **minSdk 29 (Android 10)**.

## Build and run

The bearer token is compiled in from `app/.env`, which is gitignored:

```sh
cp .env.example .env        # then set JARX_TOKEN to the backend's JARX_TOKEN
flutter run --dart-define-from-file=.env
flutter build apk --release --dart-define-from-file=.env
```

Without it the app opens on a "Built without a token" screen. The backend URL defaults to
the deployed Worker; override with `--dart-define=JARX_URL=...`.

## Verify

```sh
flutter analyze
flutter test
```

## How it fits together

| File | What it does |
| --- | --- |
| `lib/api.dart` | `Track` model, the Dio client, Riverpod providers, import chunking |
| `lib/db.dart` | Drift cache: last good copy of each library response (offline browsing) and the saved queue |
| `lib/player.dart` | audio_service handler around just_audio: queue, notification, lock screen, resume. Plays only `PlayableSource`s |
| `lib/playback.dart` | The playback contract: `TrackRef`, `StreamCandidate`, `PlayableSource`, `QualitySelector`, and `SourceResolver` (track → what to play) |
| `lib/search.dart` | Search: music, then a separate YouTube video section |
| `lib/library.dart` | Favorites, history, playlists, import |
| `lib/now_playing.dart` | Mini player and the full player with seek bar and queue |

Playback: the player asks `SourceResolver` for a track's `PlayableSource` (a URI plus optional
headers) and knows nothing else about providers. The resolver gets stream candidates (from
`/stream` for now; `/streams` exists for the next step), drops expired or invalid ones, and lets
`QualitySelector` pick, caching candidates in memory for the session. A track saved with a
`streamUrl` has it tried once first, as a legacy hint. If a source fails to load, the player
re-resolves and retries once, then skips the track; a track that can't be resolved at all
(offline, say) stays put with the reason shown. The next track is prefetched.

Search shows music first. YouTube videos sit below a separator labelled "Video playback
(ads included)", each marked with the [Y] source badge. YouTube results are metadata only:
tapping one opens the YouTube app (or a browser), ads included; JARX never plays YouTube audio.
JioSaavn rows sit with the music, marked [J] and "Open in JioSaavn": JARX can't play them
(their audio is protected media), so tapping one opens the song in the JioSaavn app or a browser.
Source badges and those hand-off labels live in `providers` in `lib/widgets.dart`; YM and L get
added there as those providers are built.
