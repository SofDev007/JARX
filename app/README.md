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
| `lib/player.dart` | audio_service handler around just_audio: queue, notification, lock screen, resume |
| `lib/search.dart` | Search, including the "found on YouTube" answer state |
| `lib/library.dart` | Favorites, history, playlists, import |
| `lib/now_playing.dart` | Mini player and the full player with seek bar and queue |

Playback uses the stream URL a track already carries and only asks `/stream` for a fresh one
if the player fails. Jamendo's URLs never expire, Archive's are stable, and Audius's are
signed and do expire.

Search shows music first. YouTube videos sit below a separator labelled "Video playback
(ads included)", each marked with the [Y] source badge. YouTube results are metadata only:
tapping one opens the YouTube app (or a browser), ads included; JARX never plays YouTube audio.
Source badges live in `providers` in `lib/widgets.dart`: J, YM and L get added there as those
providers are built.
