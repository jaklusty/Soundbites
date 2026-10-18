/// The real controller: wraps the engine and runtime, and adds the Flutter-only pieces (folder
/// picker, open in browser, reveal in Finder/Explorer).
library;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../engine/engine.dart';
import '../engine/file_log.dart';
import '../engine/library.dart';
import '../engine/runtime.dart';
import '../engine/state.dart';
import '../engine/tools.dart' as tools;
import 'controller.dart';

class EngineController implements SoundbitesController {
  EngineController({required this.engine, required this.toolsDir, required this.ffmpegPath, this.skipTools = false, this.logPath})
      : _log = logPath == null ? null : FileLog(logPath) {
    _sub = engine.states.listen((s) => _state.value = s);
    _log?.call('Soundbites ${engine.version} starting');
  }

  final Engine engine;
  final String toolsDir, ffmpegPath;
  final bool skipTools;
  @override
  final String? logPath;
  final FileLog? _log;

  void _logLine(String line) {
    debugPrint(line);
    _log?.call(line);
  }
  Runtime? _runtime;
  late final StreamSubscription<AppState> _sub;
  final ValueNotifier<AppState> _state = ValueNotifier(AppState(version: '', library: LibraryState.none));

  @override
  ValueListenable<AppState> get state => _state;

  Future<void> start() async {
    await engine.start();
    _state.value = await engine.snapshot();
    if (engine.isOpen) _startRuntime();
  }

  void _startRuntime() {
    _runtime?.stop();
    _runtime = Runtime(
      engine,
      RuntimeOptions(
        toolsDir: toolsDir,
        ffmpegPath: ffmpegPath,
        platform: Platform.isWindows ? tools.Platform.win32 : tools.Platform.darwin,
        arch: _arch(),
        skipTools: skipTools,
        log: _logLine,
      ),
    );
    unawaited(_runtime!.start());
  }

  tools.Arch _arch() {
    final v = Platform.version.toLowerCase();
    return v.contains('arm64') || v.contains('aarch64') ? tools.Arch.arm64 : tools.Arch.x64;
  }

  Future<void> dispose() async {
    _runtime?.stop();
    await _log?.close();
    await _sub.cancel();
    await engine.dispose();
  }

  Future<void> _afterOpen() async {
    _state.value = await engine.snapshot();
    if (engine.isOpen) _startRuntime();
  }

  @override
  Future<void> chooseLibraryFolder() async {
    final dir = await getDirectoryPath(confirmButtonText: 'Use this folder');
    if (dir == null) return;
    await engine.open(dir);
    await _afterOpen();
  }

  @override
  Future<void> createLibraryHere(String path) async {
    if (path != engine.libraryPath) return;
    await engine.createHere(path);
    await _afterOpen();
  }

  @override
  Future<void> reopenLibrary() async {
    final path = engine.settings.current.libraryPath;
    if (path == null) return;
    await engine.open(path);
    await _afterOpen();
  }

  @override
  Future<void> takeOverLock() async {
    await engine.takeOver();
    await _afterOpen();
  }

  @override
  Future<void> star(String id, bool on) => engine.star(id, on);

  @override
  Future<({int removed, int freed})> reclaim() => engine.reclaimSpace();

  @override
  Future<void> setActiveView(String key) => engine.setActiveView(key);

  @override
  Future<void> saveViewRule(String key, Map<String, dynamic> rule) => engine.saveViewRule(key, rule);

  @override
  Future<void> updateSettings({String? feedBase, int? concurrency, int? requestPauseMs}) async {
    final before = engine.settings.current;
    await engine.updateSettings((c) => c.copyWith(feedBase: feedBase ?? c.feedBase, concurrency: concurrency ?? c.concurrency, requestPauseMs: requestPauseMs ?? c.requestPauseMs));
    if (engine.settings.current.feedBase != before.feedBase) unawaited(_runtime?.checkFeed());
  }

  @override
  Future<void> openExternal(String url) async {
    // Links to YouTube open in the user's own browser, after checking they are http(s).
    final u = Uri.tryParse(url);
    if (u == null || !(u.scheme == 'http' || u.scheme == 'https')) return;
    await launchUrl(u, mode: LaunchMode.externalApplication);
  }

  @override
  String? mediaPath(String kind, String id) {
    final root = engine.libraryPath;
    if (root == null) return null;
    final t = _state.value.tracks.where((x) => x.id == id).firstOrNull;
    if (t == null) return null;
    final rel = kind == 'clip' ? (t.clipPresent ? t.clip : null) : t.full;
    if (rel == null) return null;
    final path = p.join(root, rel);
    return File(path).existsSync() ? path : null;
  }

  @override
  Future<void> showLogFile() async {
    final path = logPath;
    if (path == null) return;
    await _reveal(path);
  }

  @override
  Future<void> showInFolder(String kind, String id) async {
    final path = mediaPath(kind, id);
    if (path == null) return;
    await _reveal(path);
  }

  Future<void> _reveal(String path) async {
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', path]);
    } else {
      await Process.run('xdg-open', [p.dirname(path)]);
    }
  }

  @override
  Future<void> retryTrack(String id) async => _runtime?.retryTrack(id);

  @override
  Future<void> wrongTrack(String id, bool alsoRemoveFull) async {
    await engine.rejectMatch(id, alsoRemoveFull);
    await _runtime?.retryTrack(id);
  }

  @override
  Future<void> setTrackLink(String id, String url) async {
    final safe = youtubeUrlOnly(url);
    if (safe == null) throw Exception('That is not a YouTube link.');
    await engine.setTrackLink(id, safe);
    await _runtime?.retryTrack(id);
  }

  @override
  Future<void> checkFeedNow() async => _runtime?.checkFeed();

  @override
  Future<void> pauseDownloads(bool paused) async => _runtime?.pause(paused);

  @override
  Future<void> cancelDownloads() async => _runtime?.cancel();

  @override
  Future<void> clearIssue(int index) => engine.clearIssue(index);
}
