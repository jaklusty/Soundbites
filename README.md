# Soundbites

A desktop library of trending sounds for short-form video. It shows a library of 30-second
audition clips, plays them, lets you star tracks (which downloads the full song), and keeps the
library up to date from a shared online feed. Runs on macOS (Apple Silicon and Intel) and Windows
10/11. Nothing else to install.

Status: in development. Written in Flutter; the earlier Electron version lives on the `electron`
branch. See `docs/` for the design notes, the signing switch and the first-time-opening guide.

## Layout

```
lib/engine/          the engine: store, ids, hook, ingest, promote, feed, tools, runtime (plain Dart)
lib/ui/              the screens, player and controller
lib/main.dart        start-up: finds ffmpeg, opens the window, picks the controller
test/engine/         engine tests, including the Python oracles and the parity check
test/ui/             tests for the section and filter rules
test/fixtures/       oracles, a feed snapshot and an 87-track demo library
macos/ windows/ linux/   the platform runners (Linux is for headless checks only)
installer/windows/   the Inno Setup script for the Windows installer
scripts/             fetch-ffmpeg, package-mac, package-windows, smoke-linux, prepare-parity
assets/icon/         the app icon (placeholder until the logo is chosen)
design/logo/         icon variants
docs/                design notes, SIGNING.md, first-time-opening guide, moving-over notes
LICENSES/            licence texts shown in About (ffmpeg, LAME, yt-dlp, Deno)
reference/python/    the original Python scripts the engine must match
.github/workflows/   ffmpeg.yml builds the LGPL ffmpeg; build.yml builds the installers
```

## Developing

Needs the Flutter SDK (3.47 or later) and, for drag-and-drop, a Rust toolchain.

```
flutter pub get
flutter test                      # unit tests (about 120)
dart analyze --fatal-infos
flutter run -d macos              # or -d windows
```

To look at the app with sample data and no real library, set `SOUNDBITES_DEMO_LIBRARY` to a
library folder (for example `test/fixtures/demo-library`) before running.

The Python-parity check is skipped unless prepared:

```
scripts/prepare-parity.sh <folder with ingest.py and library.json> /tmp/parity
SOUNDBITES_PARITY=/tmp/parity flutter test test/engine/parity_test.dart
```

Packaging happens in GitHub Actions (`Build app` workflow): a universal `.dmg` on a macOS runner
and an Inno Setup installer on a Windows runner. Run the `ffmpeg (LGPL)` workflow first and pass
its release tag when starting `Build app` (or set the repository variable `FFMPEG_RELEASE`).
Current ffmpeg release: `ffmpeg-n8.1.3-3`. Giving the run a `release_tag` publishes a pre-release.

`assets/icon/icon.png` is a neutral placeholder until the logo is chosen; replace it with a
1024x1024 PNG of the chosen variant from `design/logo/` and regenerate the platform icons
(`macos/Runner/Assets.xcassets`, `windows/runner/resources/app_icon.ico`).

## Third-party programs

- **ffmpeg** and **ffprobe**, built by us from unmodified FFmpeg source with LAME for MP3
  encoding, LGPL v2.1 or later, no GPL or nonfree parts. Bundled with the app. Licence texts in
  `LICENSES/`; the exact source tarballs and build recipe are attached to each `ffmpeg-*`
  release in this repository.
- **yt-dlp** (Unlicense) and **Deno** (MIT) are not bundled. The app downloads the official
  builds on first run and verifies them against the publishers' checksums.
