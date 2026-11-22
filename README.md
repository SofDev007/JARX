# JARX

**Jaiswal Audio Response eXperience**: a personal music player for Android,
built with Flutter and Rust. It plays your local music alongside streams from a
sandboxed WebAssembly plugin system, learns what you like on your device, and
keeps your library in sync across your phones through your Google account.

<p align="center">
  <img src="docs/screenshots/home.png" width="24%" alt="Home" />
  <img src="docs/screenshots/player.png" width="24%" alt="Player" />
  <img src="docs/screenshots/video.png" width="24%" alt="Music video" />
  <img src="docs/screenshots/lyrics.png" width="24%" alt="Synced lyrics" />
</p>

**[Download the latest APK](https://github.com/SofDev007/Jaiswal-audio/releases/latest)**
(`jarx_android_…_arm64-v8a.apk`). Open it on your phone and, if Android asks,
allow your browser to install apps. After that, JARX updates itself.

## Features

### Listening

- **Plugins:** `.bex` plugins for search, streaming (JioSaavn, YouTube Music,
  YouTube Video), charts, lyrics and playlist import, run in a sandboxed
  Rust/WebAssembly runtime. Plugins are checked against a fingerprint before
  install and update themselves.
- **Local music** in the same library as streams.
- **Queue that plays in order:** songs you add play next, in the order you
  added them, before the rest of the playlist and before suggestions, shuffle
  included.
- **Smart shuffle:** your playlist shuffled with a suggested song after every
  three. Keep a suggestion with **+**, or never see it again with **−**.
- **Replays without data:** songs you finish are kept on the phone (up to
  300 MB), so playing them again uses no data.
- **Music videos up to 1080p:** songs from the YouTube Video plugin can show
  their video in place of the cover, in time with the song, with full-screen
  controls and captions in the video's own languages.
- **Synced lyrics:** tap a line the moment you hear it and JARX lines the
  lyrics up; fine-tune 0.1 s at a time.
- **Equalizer, crossfade, sleep timer** and **Discord Rich Presence**
  (optional, desktop).

<p align="center">
  <img src="docs/screenshots/smart-shuffle.png" width="24%" alt="Smart shuffle" />
  <img src="docs/screenshots/video-fullscreen.png" width="72%" alt="Full-screen video with captions" />
</p>

### Your library

- **Sign in with Google:** playlists, Liked songs, recent plays and your taste
  profile follow you. Two phones stay in sync within a minute.
- **One space per account:** switch between Google accounts on the same phone
  without mixing music.
- **Playlist import:** Spotify links and CSV exports (Exportify, TuneMyMusic
  and similar), with match confidence shown for every track.
- **Downloads:** a whole playlist shows as one card in Offline ("27 of 59
  downloaded") with Pause all and Cancel all. Downloads resume after JARX
  closes.
- **Backup and restore** of your library and settings (JSON, M3U).

<p align="center">
  <img src="docs/screenshots/library.png" width="24%" alt="Library" />
  <img src="docs/screenshots/offline.png" width="24%" alt="Offline downloads" />
  <img src="docs/screenshots/account.png" width="24%" alt="Account and sync" />
</p>

### Made for you

- **On-device recommendations:** autoplay ranked by what you play, like and
  skip, with a short reason for each pick. Your taste profile is computed on
  your phone.
- **Your corner:** tap your photo on Home for this month's listening time,
  your top 5 artists and songs, and a silly comparison.
- **Quick start:** new users pick languages, a few favourite artists and a Home
  layout, and can bring their Spotify playlists over. Recommendations start
  from those picks.

<p align="center">
  <img src="docs/screenshots/your-corner.png" width="24%" alt="Your corner" />
  <img src="docs/screenshots/first-run.png" width="24%" alt="Quick start" />
</p>

### Always up to date

- **In-app updates:** the bell on Home shows new versions with what changed
  since yours; tap Update and JARX downloads and installs it.
- **Interface in 7 languages:** English, Hindi, German, Spanish, Japanese,
  Korean and Chinese.

## Privacy

Listening history and recommendations are computed on your phone. Signing in
syncs your playlists, likes, recent plays and taste profile to the JARX server
so your other phones get them. JARX blocks plain `http` traffic and Android
backups of its data. See the
[privacy policy](https://jarx.jarx-backend.workers.dev/privacy).

## Building

Requirements: Flutter (stable, 3.35), Rust (`rustup`), and for Android the
Android SDK, NDK and JDK 17. The Rust part is built automatically by the
Flutter build.

```sh
flutter pub get
flutter run                 # debug on a connected device
flutter test                # unit and widget tests
```

The project also builds for Windows and Linux; releases are Android only.
See [ARCHITECTURE.md](ARCHITECTURE.md) for how the pieces fit together and
[`server/`](server) for the sync backend (Cloudflare Workers).

## Credits and license

JARX is based on [BloomeeTunes](https://github.com/HemantKArya/BloomeeTunes)
and, like it, is licensed under the GNU General Public License, version 2. See
[NOTICE](NOTICE) and [LICENSE](LICENSE).
