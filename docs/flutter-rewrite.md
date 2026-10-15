# Flutter rewrite: design note

Jak asked on 15 October 2026 for the app to be redesigned and rewritten in Flutter instead of
Electron. The Electron version is kept on the `electron` branch (its last build is the v0.1.0
pre-release). This note records what changes and what does not.

## What stays exactly as it was

- The build brief's hard requirements, the feed contract, the library file formats
  (library.json version 1, favourites.json, profile.json, feed_state.json) and the track ids.
- The LGPL ffmpeg build (`.github/workflows/ffmpeg.yml`, release `ffmpeg-n8.1.3-3`).
- The test oracles generated from the Python: every id in the real library, 3,000 generated
  titles, 422 heatmaps, and the Python-parity ingest check.
- The logo work, the first-time-opening guide, the Phase 5 moving-over notes, the licences.

## What the Flutter version does differently

- **Direct file access.** A Flutter desktop app is not sandboxed the way an Electron page is,
  so clips and full tracks play straight from the library folder. No custom protocol, no range
  server.
- **One language, one process.** The engine (store, ids, ingest, hook, promote, feed, tools,
  runtime) is plain Dart under `lib/engine/` with no Flutter imports, so it is unit-tested with
  `flutter test` and could run headless. The UI under `lib/ui/` talks to it through a small
  controller; the engine pushes a state snapshot after every change, as before.
- **Native pieces come from packages:** `just_audio` (macOS; Windows and Linux through
  `just_audio_media_kit`) for playback with seeking, `super_drag_and_drop` for dragging a clip
  into DaVinci Resolve, `file_selector` for the folder picker, `window_manager` for window
  state, `url_launcher` for YouTube links, `unorm_dart` for the Unicode normalisation the ids
  need, `crypto` for SHA-1, `archive` for unzipping Deno.
- **Processes.** yt-dlp and ffmpeg run through `Process.run` with argument lists. No shell.
- **Locks.** The library-folder lock keeps the heartbeat design (a directory with owner.json),
  because it has to be visible to another computer. The single-instance lock uses an OS file
  lock (`RandomAccessFile.lock`) on a file in the app-data folder, which the OS releases if the
  app crashes.
- **Packaging.** `flutter build macos` produces a universal app by default. The workflow copies
  ffmpeg into `Contents/Resources/ffmpeg/`, turns the App Sandbox entitlement off (the app must
  spawn yt-dlp and read any folder the user picks), ad-hoc signs the whole bundle with
  `codesign --force --deep --sign -`, verifies it, and makes the .dmg with `hdiutil`. On Windows
  `flutter build windows` plus an Inno Setup script makes the installer. Both still run on the
  real runners, never cross-compiled. The signing switch stays documented in `docs/SIGNING.md`.
- **Size.** Roughly 60 MB installed instead of 270 MB.

## The redesign

Same sections, search, filters, playback, starring, Needs attention, storage footer and saved
views, but drawn fresh with Flutter widgets rather than ported from the old page. A first
screenshot goes to Jak early for a yes or no on the direction before the detail work.

## Order of work

1. Engine port with the existing oracles (ids first), then store, hook, ingest, promote, feed,
   tools, runtime. Same tests as before.
2. UI: first-launch flow, library screen, player, settings, about.
3. Linux headless smoke run in CI, then the macOS and Windows packaging workflow.
4. Phase 4 and 5 as in the brief.
