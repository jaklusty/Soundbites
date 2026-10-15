# Engine conventions

Plain Dart only under `lib/engine/` (no `package:flutter` imports), so everything here runs
under `flutter test` and headless. Each file is a port of the TypeScript module of the same
name from the `electron` branch; the TypeScript and its tests are the spec. Where the build
brief says to behave differently from the Python, the brief wins.

- JSON state files are maps (`Json = Map<String, dynamic>`), wrapped by `Track`, `Library`,
  `Favourites` in `library.dart`. Never rebuild a record from typed fields: edit the map, so
  unknown keys and key order survive.
- Write files only through `Store` (`store.dart`): atomic write, `.bak`, lock, corrupt handling.
- Timestamps: `nowIso()` (seconds, `+00:00`), matching the Python.
- Run external programs with `Process.run(exe, [args])`, never a shell string; `--` before URLs.
- Every failure the user should know about becomes a health event (`health.dart`), one line per
  run, never only a log line. No message mentions Python, Claude or "the server".
- Tests live in `test/engine/`, fixtures in `test/fixtures/` (the Python oracles are already
  there: `slugify-oracle.json`, `heatmap-oracle.json`, `feed/`).
