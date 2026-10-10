# Soundbites

A desktop library of trending sounds for short-form video. It shows a library of 30-second
audition clips, plays them, lets you star tracks (which downloads the full song), and keeps the
library up to date from a shared online feed. Runs on macOS (Apple Silicon and Intel) and Windows
10/11. Nothing else to install.

Status: in development. See `docs/` for the design note, the signing switch and the
first-time-opening guide.

## Layout

```
src/main/            Electron main process: the engine (store, ingest, hook, promote, feed, tools)
src/preload/         the narrow bridge the sandboxed page may call
src/renderer/        the dashboard page
test/                unit tests (vitest)
build/               icon and entitlements used by electron-builder
scripts/             build helpers (fetching the bundled ffmpeg)
design/logo/         icon variants
docs/                design note, SIGNING.md, first-time-opening guide
LICENSES/            licence texts shown in About (ffmpeg, LAME, yt-dlp, Deno)
.github/workflows/   ffmpeg.yml builds the LGPL ffmpeg; build.yml builds the installers
```

## Developing

```
npm install
npm test            # unit tests
npm run typecheck
npm run dev         # run the app with live reload
```

Packaging happens in GitHub Actions (`Build app` workflow): a universal `.dmg` on a macOS runner
and an NSIS installer on a Windows runner. Run the `ffmpeg (LGPL)` workflow first and pass its
release tag (or set the repository variable `FFMPEG_RELEASE`).

## Third-party programs

- **ffmpeg** and **ffprobe**, built by us from unmodified FFmpeg source with LAME for MP3
  encoding, LGPL v2.1 or later, no GPL or nonfree parts. Bundled with the app. Licence texts in
  `LICENSES/`; the exact source tarballs and build recipe are attached to each `ffmpeg-*`
  release in this repository.
- **yt-dlp** (Unlicense) and **Deno** (MIT) are not bundled. The app downloads the official
  builds on first run and verifies them against the publishers' checksums.
