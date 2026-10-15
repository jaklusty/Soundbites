/// The engine: owns the open library, answers every operation the UI can ask for, and pushes a
/// fresh state snapshot after each change. Plain Dart; the Flutter side wraps it in a controller.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'health.dart';
import 'library.dart';
import 'library_lock.dart';
import 'library_open.dart';
import 'promote.dart';
import 'settings.dart';
import 'state.dart';
import 'store.dart';
import 'views.dart';

class Engine {
  Engine({required String appDataDir, required this.version}) : settings = Settings(appDataDir);

  final Settings settings;
  final String version;
  Store? store;
  LibraryLock? _lock;
  LibraryState _library = LibraryState.none;
  FeedStatus feed = FeedStatus();
  ToolsStatus tools = ToolsStatus();
  String? promoting;
  UpdateInfo? update;
  Timer? _pushTimer;
  final _state = StreamController<AppState>.broadcast();
  final _promoteQueued = StreamController<String>.broadcast();

  Stream<AppState> get states => _state.stream;
  Stream<String> get promoteQueued => _promoteQueued.stream;
  LibraryState get library => _library;
  String? get libraryPath => _library.path;
  bool get isOpen => _library.status == LibraryStatus.open;

  // ------------------------------------------------------------------ lifecycle

  Future<void> start() async {
    final s = await settings.load();
    if (s.libraryPath != null) await open(s.libraryPath!);
  }

  /// Open a folder. Never creates a library; see createHere().
  Future<LibraryState> open(String path) async {
    await close();
    final probe = await probeLibrary(path);
    switch (probe) {
      case ProbeMissing():
        _library = LibraryState(status: LibraryStatus.missing, path: path);
      case ProbeNotAFolder():
        _library = LibraryState(status: LibraryStatus.error, path: path, message: 'That is a file, not a folder.');
      case ProbeEmpty(:final warnings):
        _library = LibraryState(status: LibraryStatus.empty, path: path, warnings: warnings);
      case ProbeOk(:final warnings):
        final lock = LibraryLock(path);
        final r = await lock.acquire();
        if (r.status == AcquireStatus.held) {
          _library = LibraryState(status: LibraryStatus.held, path: path, owner: _owner(r.owner));
        } else if (r.status == AcquireStatus.stale) {
          _library = LibraryState(status: LibraryStatus.stale, path: path, owner: _owner(r.owner));
        } else {
          _lock = lock;
          store = Store(path, onHealth: (e) => unawaited(_onStoreHealth(e)));
          _library = LibraryState(status: LibraryStatus.open, path: path, warnings: warnings);
          try {
            await store!.read('library.json');
            await store!.read('favourites.json');
            await store!.read('profile.json');
          } on StoreError catch (e) {
            await close();
            _library = LibraryState(status: LibraryStatus.error, path: path, message: e.message);
          }
        }
    }
    await settings.update((c) => c.copyWith(libraryPath: path));
    push();
    return _library;
  }

  LockOwnerInfo? _owner(LockOwner? o) => o == null ? null : LockOwnerInfo(host: o.host, user: o.user, pid: o.pid, app: o.app, started: o.started, heartbeat: o.heartbeat);

  Future<LibraryState> createHere(String path) async {
    final probe = await probeLibrary(path);
    if (probe is! ProbeEmpty) return open(path);
    await createLibrary(path);
    return open(path);
  }

  Future<LibraryState> takeOver() async {
    final path = libraryPath;
    if (path == null || _library.status != LibraryStatus.stale) return _library;
    final lock = LibraryLock(path);
    await lock.takeOver();
    await lock.release();
    return open(path);
  }

  Future<void> close() async {
    await _lock?.release();
    _lock = null;
    store = null;
    _library = LibraryState.none;
  }

  Future<void> dispose() async {
    _pushTimer?.cancel();
    await close();
    await _state.close();
    await _promoteQueued.close();
  }

  Future<void> _onStoreHealth(HealthEvent e) async {
    if (store != null && e.level != 'info') await record(store!, 'storage', false, e.message);
    push();
  }

  // ------------------------------------------------------------------ state

  /// Debounced push of a fresh snapshot to listeners.
  void push() {
    if (_pushTimer != null) return;
    _pushTimer = Timer(const Duration(milliseconds: 40), () {
      _pushTimer = null;
      unawaited(snapshot().then((s) {
        if (!_state.isClosed) _state.add(s);
      }));
    });
  }

  Future<AppState> snapshot() async {
    final s = settings.current;
    var base = AppState(version: version, library: _library, libraryPath: libraryPath, promoting: promoting, feed: feed, tools: tools, update: update, feedBase: s.feedBase, concurrency: s.concurrency, requestPauseMs: s.requestPauseMs);
    final st = store;
    if (st == null || !isOpen) return base;
    try {
      final lib = Library(await st.readOr('library.json', Library.empty().json));
      final favs = Favourites(await st.readOr('favourites.json', Favourites.empty().json));
      final profile = await st.readOr('profile.json', <String, dynamic>{});
      final queue = await st.readOr('promote_queue.json', <String, dynamic>{'ids': <String>[]});
      final health = await st.readOr('health.json', <String, dynamic>{'events': <dynamic>[]});
      final lastRun = (await st.read('last_run.json')).data;
      final pending = await pendingFiles();
      final rec = await reclaimable(st);
      final issues = ((health['events'] as List?) ?? const [])
          .whereType<Map>()
          .where((e) => e['ok'] != true)
          .map((e) => HealthIssue(at: (e['at'] ?? '').toString(), kind: (e['kind'] ?? '').toString(), message: (e['message'] ?? '').toString(), detail: (e['detail'] ?? '').toString()))
          .toList();
      base = AppState(
        version: version,
        library: _library,
        libraryPath: libraryPath,
        tracks: lib.tracks,
        lastRun: lib.lastRun,
        favourites: favs.ids.toSet(),
        promoteQueue: ((queue['ids'] as List?) ?? const []).map((e) => e.toString()).toList(),
        promoting: promoting,
        profile: profile,
        activeView: ((profile['views'] as Map?)?['active'] ?? '').toString(),
        issues: issues.length > 8 ? issues.sublist(issues.length - 8) : issues,
        pending: pending,
        lastRunSummary: lastRun,
        reclaimableCount: rec.count,
        reclaimableBytes: rec.bytes,
        feed: feed,
        tools: tools,
        update: update,
        feedBase: s.feedBase,
        concurrency: s.concurrency,
        requestPauseMs: s.requestPauseMs,
      );
    } on StoreError catch (e) {
      base = AppState(version: version, library: _library, libraryPath: libraryPath, feed: feed, tools: tools, issues: [HealthIssue(at: nowIso(), kind: 'storage', message: e.message)], feedBase: s.feedBase, concurrency: s.concurrency, requestPauseMs: s.requestPauseMs);
    }
    return base;
  }

  Future<List<String>> pendingFiles() async {
    final path = libraryPath;
    if (path == null) return [];
    final dir = Directory(p.join(path, 'pending'));
    if (!await dir.exists()) return [];
    final names = <String>[];
    await for (final e in dir.list()) {
      if (e is File && p.basename(e.path).toLowerCase().endsWith('.json')) names.add(p.basename(e.path));
    }
    return names..sort();
  }

  // ------------------------------------------------------------------ operations

  Store _need() {
    final st = store;
    if (st == null || !isOpen) throw StateError('No library is open');
    return st;
  }

  /// Star or unstar. Starring is the only thing that queues a full-track download.
  Future<bool> star(String id, bool on) async {
    final st = _need();
    await st.withLock(() async {
      final lib = Library(await st.readOr('library.json', Library.empty().json));
      if (lib.find(id) == null) throw StateError('No such track');
      final favs = Favourites(await st.readOr('favourites.json', Favourites.empty().json));
      final ids = favs.ids.toSet();
      if (on) {
        ids.add(id);
      } else {
        ids.remove(id);
      }
      favs.ids = ids.toList()..sort();
      final stamp = nowIso();
      favs.json['updated'] = stamp;
      final starredAt = (favs.json['starred_at'] ??= <String, dynamic>{}) as Map;
      if (on) {
        starredAt.putIfAbsent(id, () => stamp);
      } else {
        starredAt.remove(id);
      }
      await st.writeUnlocked('favourites.json', favs.json);
    });
    var queued = false;
    if (on) queued = await queuePromotion(st, id);
    push();
    if (queued) _promoteQueued.add(id);
    return queued;
  }

  Future<({int removed, int freed})> reclaimSpace() async {
    final st = _need();
    final r = await reclaim(st);
    push();
    return (removed: r.removed.length, freed: r.freed);
  }

  Future<void> setActiveView(String key) async {
    final st = _need();
    await st.update('profile.json', <String, dynamic>{}, (pr) {
      final views = (pr['views'] ??= <String, dynamic>{'saved': <String, dynamic>{}}) as Map;
      final saved = (views['saved'] as Map?) ?? const {};
      views['active'] = key.isNotEmpty && saved.containsKey(key) ? key : '';
      return pr;
    });
    push();
  }

  Future<void> saveViewRule(String key, Map<String, dynamic> rule) async {
    final st = _need();
    if (!isValidRule(rule)) throw StateError('That rule has no conditions');
    await st.update('profile.json', <String, dynamic>{}, (pr) {
      final views = (pr['views'] ??= <String, dynamic>{}) as Map;
      final saved = (views['saved'] ??= <String, dynamic>{}) as Map;
      final view = (saved[key] ??= <String, dynamic>{'label': key}) as Map;
      view['rule'] = rule;
      return pr;
    });
    push();
  }

  Future<AppSettings> updateSettings(AppSettings Function(AppSettings) patch) async {
    final before = settings.current;
    final next = await settings.update(patch);
    if (next.libraryPath != null && next.libraryPath != before.libraryPath) await open(next.libraryPath!);
    push();
    return next;
  }

  Future<void> clearIssue(int index) async {
    final st = _need();
    await st.update('health.json', <String, dynamic>{'events': <dynamic>[]}, (h) {
      final events = ((h['events'] as List?) ?? const []).whereType<Map>().toList();
      final bad = events.where((e) => e['ok'] != true).toList();
      final visible = bad.length > 8 ? bad.sublist(bad.length - 8) : bad;
      if (index < 0 || index >= visible.length) return null;
      final target = visible[index];
      h['events'] = events.where((e) => !identical(e, target)).toList();
      return h;
    });
    push();
  }

  /// The user pasted a YouTube link for an existing track. The current clip is removed so the
  /// next fetch cuts it from the new upload; the link is never overwritten by a later feed run.
  Future<void> setTrackLink(String id, String url) async {
    final st = _need();
    await st.withLock(() async {
      final lib = Library(await st.readOr('library.json', Library.empty().json));
      final t = lib.find(id);
      if (t == null) throw StateError('No such track');
      if (t.clip != null) {
        final f = File(p.join(st.root, t.clip!));
        if (await f.exists()) await f.delete();
      }
      t.set('clip_present', false);
      for (final k in ['clip_bytes', 'hook_at', 'hook_method', 'hook_detail', 'match']) {
        t.remove(k);
      }
      t.set('user_source_url', url);
      t.set('source_url', url);
      t.set('match_status', 'user-link');
      lib.updated = nowIso();
      await st.writeUnlocked('library.json', lib.json);
    });
    push();
  }

  /// Remove a wrong clip (and optionally the full track), remember the rejected video id.
  Future<Track?> rejectMatch(String id, bool alsoRemoveFull) async {
    final st = _need();
    Track? out;
    await st.withLock(() async {
      final lib = Library(await st.readOr('library.json', Library.empty().json));
      final t = lib.find(id);
      if (t == null) throw StateError('No such track');
      final rejectedId = (t.match?['video_id'] ?? '').toString().isNotEmpty ? t.match!['video_id'].toString() : (t.sourceUrl == null ? null : youtubeVideoId(t.sourceUrl!));
      if (rejectedId != null) t.set('rejected_video_ids', {...t.rejectedVideoIds, rejectedId}.toList());
      if (t.clip != null) {
        final f = File(p.join(st.root, t.clip!));
        if (await f.exists()) await f.delete();
      }
      t.set('clip_present', false);
      for (final k in ['clip_bytes', 'hook_at', 'hook_method', 'hook_detail', 'match', 'match_status']) {
        t.remove(k);
      }
      if (t.userSourceUrl == null) t.remove('source_url');
      if (alsoRemoveFull && t.full != null) {
        final d = Directory(p.join(st.root, 'full', t.id));
        if (await d.exists()) await d.delete(recursive: true);
        for (final k in ['full', 'full_format', 'full_bytes', 'promoted_at']) {
          t.remove(k);
        }
      }
      out = t;
      lib.updated = nowIso();
      await st.writeUnlocked('library.json', lib.json);
    });
    push();
    return out;
  }

  Future<void> recordIssue(String kind, String message, [String detail = '']) async {
    if (store != null) await record(store!, kind, false, message, detail);
    push();
  }
}
