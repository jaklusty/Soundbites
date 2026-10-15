/// Keeps yt-dlp and Deno installed in the app-data folder and up to date: first run, weekly, once
/// after an extractor failure, and again if a file goes missing (antivirus sometimes removes it).
/// Downloads go to versioned file names and switch over only after the checksum passes.
library;

import 'dart:io' hide Platform;

import 'package:path/path.dart' as p;

import 'tools.dart';
import 'zip.dart';

class ToolPaths {
  ToolPaths({this.ytdlp, this.deno});

  String? ytdlp;
  String? deno;
}

const int weekMs = 7 * 24 * 3600 * 1000;

class ToolManager {
  ToolManager({required String toolsDir, required this.platform, required this.arch, FetchLike? fetch, void Function(String line)? log})
      : _dir = toolsDir,
        _fetch = fetch ?? defaultFetch,
        _log = log ?? ((_) {});

  final String _dir;
  final Platform platform;
  final Arch arch;
  final FetchLike _fetch;
  final void Function(String line) _log;
  Future<ToolPaths>? _installing;

  /// Set by [ensure]: what Needs attention should say, or null when all is well.
  String? lastMessage;

  /// What is on disk right now (newest build of each), without touching the network.
  Future<ToolPaths> installed() async {
    final files = await _readdir();
    final y = pickInstalled(files, toolSpec(ToolName.ytDlp, platform, arch), platform);
    final d = pickInstalled(files, toolSpec(ToolName.deno, platform, arch), platform);
    return ToolPaths(ytdlp: y == null ? null : p.join(_dir, y), deno: d == null ? null : p.join(_dir, d));
  }

  ({String? ytdlp, String? deno}) versions(ToolPaths paths) {
    String? tag(String? path, String base) =>
        path?.split(RegExp(r'[\\/]')).last.replaceFirst(RegExp('^${RegExp.escape(base)}-'), '').replaceFirst(RegExp(r'\.exe$'), '');
    return (ytdlp: tag(paths.ytdlp, 'yt-dlp'), deno: tag(paths.deno, 'deno'));
  }

  /// Make sure both tools exist, downloading what is missing. With `checkForNewer`, also look for
  /// a newer release of each (the weekly / after-failure check). Never throws: returns what is
  /// usable and sets [lastMessage] for Needs attention. Only one ensure runs at a time; a second
  /// call while one is in flight shares its result.
  Future<ToolPaths> ensure(bool checkForNewer) {
    final running = _installing;
    if (running != null) return running;
    final f = _doEnsure(checkForNewer).whenComplete(() => _installing = null);
    _installing = f;
    return f;
  }

  Future<ToolPaths> _doEnsure(bool checkForNewer) async {
    await Directory(_dir).create(recursive: true);
    final have = await installed();
    final problems = <String>[];
    for (final name in [ToolName.ytDlp, ToolName.deno]) {
      final current = name == ToolName.ytDlp ? have.ytdlp : have.deno;
      if (current != null && !checkForNewer) continue;
      try {
        final r = await installLatest(toolSpec(name, platform, arch), platform, _dir, fetch: _fetch, extractZipEntry: extractZipEntry);
        if (!r.alreadyPresent) _log('${name.id} ${r.tag} installed');
        if (name == ToolName.ytDlp) {
          have.ytdlp = r.path;
        } else {
          have.deno = r.path;
        }
      } catch (err) {
        final message = err is ToolDownloadError ? err.message : '$err';
        if (current == null) {
          problems.add('${name.id} could not be downloaded ($message). Downloads need it; it will be tried again.');
        } else {
          _log('${name.id}: update check failed ($message); keeping $current');
        }
      }
    }
    await pruneOld(have);
    lastMessage = problems.isEmpty ? null : problems.join(' ');
    return have;
  }

  /// A tool file that has disappeared (antivirus) is reported and re-downloaded by the caller.
  Future<String?> verifyPresent(ToolPaths paths) async {
    for (final (name, path) in [('yt-dlp', paths.ytdlp), ('Deno', paths.deno)]) {
      if (path != null && !await File(path).exists()) {
        return '$name has gone missing from $_dir (antivirus sometimes removes it). It will be downloaded again.';
      }
    }
    return null;
  }

  /// Keep only the newest build of each tool, plus the one currently in use. Windows cannot delete a running .exe, so failures are ignored.
  Future<void> pruneOld(ToolPaths keep) async {
    final files = await _readdir();
    final keepNames = [keep.ytdlp, keep.deno].nonNulls.map((path) => path.split(RegExp(r'[\\/]')).last).toSet();
    final tool = RegExp(r'^(yt-dlp|deno)-');
    for (final f in files) {
      if (keepNames.contains(f) || f.endsWith('.part') || f.endsWith('.extracting')) continue;
      if (tool.hasMatch(f)) {
        try {
          await File(p.join(_dir, f)).delete();
        } catch (_) {
          // force: true, and a running .exe on Windows cannot be deleted.
        }
      }
    }
  }

  Future<List<String>> _readdir() async {
    try {
      return await Directory(_dir).list().map((e) => p.basename(e.path)).toList();
    } catch (_) {
      return <String>[];
    }
  }
}
