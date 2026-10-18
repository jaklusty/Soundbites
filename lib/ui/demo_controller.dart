/// A controller that reads a library folder directly and does nothing destructive. Used for
/// design previews and UI tests while the engine is being wired, and by the headless smoke run.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../engine/library.dart';
import '../engine/state.dart';
import 'controller.dart';

class DemoController implements SoundbitesController {
  DemoController(this.root) {
    _load();
  }

  final String root;
  final ValueNotifier<AppState> _state = ValueNotifier(AppState(version: 'demo', library: LibraryState.none));

  @override
  ValueListenable<AppState> get state => _state;

  Json _read(String name) {
    final f = File(p.join(root, name));
    if (!f.existsSync()) return <String, dynamic>{};
    return (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>();
  }

  void _load({Set<String>? favourites, String? activeView}) {
    final lib = Library(_read('library.json'));
    final favs = favourites ?? Favourites(_read('favourites.json')).ids.toSet();
    final profile = _read('profile.json');
    if (activeView != null) ((profile['views'] ??= <String, dynamic>{}) as Map)['active'] = activeView;
    final health = _read('health.json');
    final issues = ((health['events'] as List?) ?? const [])
        .cast<Map>()
        .where((e) => e['ok'] != true)
        .map((e) => HealthIssue(at: e['at'].toString(), kind: e['kind'].toString(), message: e['message'].toString(), detail: (e['detail'] ?? '').toString()))
        .toList();
    final lastRun = _read('last_run.json');
    var reclaimable = 0, reclaimBytes = 0;
    for (final t in lib.tracks) {
      if (t.full != null && !favs.contains(t.id)) {
        reclaimable++;
        reclaimBytes += t.fullBytes ?? 0;
      }
    }
    _state.value = AppState(
      version: 'demo',
      library: LibraryState(status: LibraryStatus.open, path: root),
      libraryPath: root,
      tracks: lib.tracks,
      lastRun: lib.lastRun,
      favourites: favs,
      profile: profile,
      activeView: ((profile['views'] as Map?)?['active'] ?? '').toString(),
      issues: issues,
      lastRunSummary: lastRun.isEmpty ? null : lastRun,
      reclaimableCount: reclaimable,
      reclaimableBytes: reclaimBytes,
      feed: FeedStatus(lastChecked: DateTime.now().toUtc().toIso8601String(), lastResult: 'up to date'),
      tools: ToolsStatus(ytdlp: 'demo', deno: 'demo', ffmpeg: 'bundled'),
      feedBase: 'https://raw.githubusercontent.com/jaklusty/Audio-Trends/main/',
    );
  }

  @override
  String? mediaPath(String kind, String id) {
    final t = _state.value.tracks.where((x) => x.id == id).firstOrNull;
    if (t == null) return null;
    final rel = kind == 'clip' ? (t.clipPresent ? t.clip : null) : t.full;
    if (rel == null) return null;
    final path = p.join(root, rel);
    return File(path).existsSync() ? path : null;
  }

  @override
  Future<void> star(String id, bool on) async {
    final favs = Set<String>.from(_state.value.favourites);
    if (on) {
      favs.add(id);
    } else {
      favs.remove(id);
    }
    _load(favourites: favs, activeView: _state.value.activeView);
  }

  @override
  Future<void> setActiveView(String key) async => _load(favourites: _state.value.favourites, activeView: key);

  @override
  Future<void> chooseLibraryFolder() async {}
  @override
  Future<void> createLibraryHere(String path) async {}
  @override
  Future<void> reopenLibrary() async {}
  @override
  Future<void> takeOverLock() async {}
  @override
  Future<({int removed, int freed})> reclaim() async => (removed: 0, freed: 0);
  @override
  Future<void> saveViewRule(String key, Map<String, dynamic> rule) async {}
  @override
  Future<void> updateSettings({String? feedBase, int? concurrency, int? requestPauseMs}) async {}
  @override
  Future<void> openExternal(String url) async {}
  @override
  Future<void> showInFolder(String kind, String id) async {}

  @override
  String? get logPath => null;
  @override
  Future<void> showLogFile() async {}
  @override
  Future<void> retryTrack(String id) async {}
  @override
  Future<void> wrongTrack(String id, bool alsoRemoveFull) async {}
  @override
  Future<void> setTrackLink(String id, String url) async {}
  @override
  Future<void> checkFeedNow() async {}
  @override
  Future<void> pauseDownloads(bool paused) async {}
  @override
  Future<void> cancelDownloads() async {}
  @override
  Future<void> clearIssue(int index) async {}
}
