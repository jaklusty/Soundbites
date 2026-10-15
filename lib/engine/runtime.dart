/// The background runtime: keeps tools installed, checks the feed on launch and every few hours,
/// runs ingest jobs one run at a time (oldest first) with visible progress, pause and cancel,
/// works the promote queue, retries tracks on request, and looks for a newer release once a day.
/// Everything that can fail reports into Needs attention via the engine.
library;

import 'dart:async';
import 'package:path/path.dart' as p;

import 'engine.dart';
import 'feed.dart';
import 'health.dart';
import 'hook.dart' show RmsResult;
import 'ingest.dart';
import 'library.dart';
import 'media.dart';
import 'promote.dart';
import 'state.dart';
import 'tool_manager.dart';
import 'tools.dart';
import 'update_check.dart';
import 'ytdlp.dart' as yt;

const feedInterval = Duration(hours: 3);
const updateInterval = Duration(hours: 24);

/// Injectable yt-dlp functions, so tests can run the whole runtime without the network.
class YtDlpImpl {
  YtDlpImpl({this.resolveSearch, this.inspect, this.downloadAudio, this.downloadFull});
  final Future<yt.ResolvedUpload?> Function(yt.YtDlpOptions o, String query, List<String> rejected)? resolveSearch;
  final Future<yt.ResolvedUpload?> Function(yt.YtDlpOptions o, String url)? inspect;
  final Future<yt.DownloadedSource?> Function(yt.YtDlpOptions o, String url, String workdir)? downloadAudio;
  final Future<yt.DownloadedSource?> Function(yt.YtDlpOptions o, String url, String workdir)? downloadFull;
}

class RuntimeOptions {
  RuntimeOptions({required this.toolsDir, required this.ffmpegPath, required this.platform, required this.arch, this.fetch, this.ytdlp, this.skipTools = false, this.now, this.log, this.clipImpl, this.measureRmsImpl, this.transcodeImpl});
  final String toolsDir, ffmpegPath;
  final Platform platform;
  final Arch arch;
  final FetchLike? fetch;
  final YtDlpImpl? ytdlp;
  final bool skipTools;
  final DateTime Function()? now;
  final void Function(String line)? log;
  /// Test hooks for the ffmpeg steps.
  final Future<MediaResult> Function(String src, String dest, double at)? clipImpl;
  final Future<RmsSeries?> Function(String src)? measureRmsImpl;
  final Future<MediaResult> Function(String src, String dest, String format)? transcodeImpl;
}

sealed class _Job {}

class _RunJob extends _Job {
  _RunJob({required this.run, required this.candidates, required this.audio, required this.source, this.path});
  final String run;
  final List<Candidate> candidates;
  final bool audio;
  final String source; // feed | pending
  final String? path;
}

class _TrackJob extends _Job {
  _TrackJob(this.id);
  final String id;
}

class Runtime {
  Runtime(this.engine, this.opts)
      : tools = ToolManager(toolsDir: opts.toolsDir, platform: opts.platform, arch: opts.arch, fetch: opts.fetch, log: opts.log) {
    _promoteSub = engine.promoteQueued.listen((_) => kickPromote());
  }

  final Engine engine;
  final RuntimeOptions opts;
  final ToolManager tools;
  final List<_Job> _queue = [];
  bool _working = false;
  bool _promoting = false;
  bool _promoteAgain = false;
  bool paused = false;
  bool _cancelled = false;
  final List<Timer> _timers = [];
  ToolPaths _toolPaths = ToolPaths();
  int _extractorFailures = 0;
  bool _toolCheckInFlight = false;
  late final StreamSubscription<String> _promoteSub;
  final _runDone = StreamController<({String run, IngestResult result})>.broadcast();

  Stream<({String run, IngestResult result})> get runDone => _runDone.stream;
  bool get working => _working;
  bool get promoting => _promoting;

  DateTime _now() => opts.now?.call() ?? DateTime.now();
  void _log(String s) => opts.log?.call(s);

  // ------------------------------------------------------------------ lifecycle

  Future<void> start() async {
    await ensureTools(false);
    _timers.add(Timer.periodic(feedInterval, (_) => checkFeed()));
    _timers.add(Timer.periodic(const Duration(hours: 6), (_) => ensureTools(true)));
    _timers.add(Timer.periodic(updateInterval, (_) => checkForUpdate()));
    unawaited(checkForUpdate());
    await checkFeed();
    kickPromote();
  }

  void stop() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    _cancelled = true;
    _queue.clear();
    _promoteSub.cancel();
  }

  // ------------------------------------------------------------------ tools

  Future<ToolPaths> ensureTools(bool checkForNewer) async {
    if (opts.skipTools) return _toolPaths;
    final s = engine.settings.current;
    final checkedAt = s.toolsCheckedAt == null ? null : DateTime.tryParse(s.toolsCheckedAt!);
    final weeklyDue = checkedAt == null || _now().difference(checkedAt).inMilliseconds > weekMs;
    final check = checkForNewer || weeklyDue;
    if (_toolCheckInFlight) return _toolPaths;
    _toolCheckInFlight = true;
    try {
      final before = tools.versions(_toolPaths).ytdlp;
      _toolPaths = await tools.ensure(check);
      if (check) await engine.settings.update((c) => c.copyWith(toolsCheckedAt: _now().toUtc().toIso8601String()));
      final v = tools.versions(_toolPaths);
      engine.tools = ToolsStatus(ytdlp: v.ytdlp, deno: v.deno, ffmpeg: 'bundled', message: tools.lastMessage);
      if (tools.lastMessage != null) {
        await engine.recordIssue('tools', tools.lastMessage!);
      } else if (engine.store != null) {
        await clearKind(engine.store!, 'tools');
      }
      // A newer yt-dlp: retry tracks left without audio, once.
      if (before != null && v.ytdlp != null && before != v.ytdlp) await _retryNoAudio();
      engine.push();
    } finally {
      _toolCheckInFlight = false;
    }
    return _toolPaths;
  }

  void _onExtractorFailure(String detail) {
    _extractorFailures++;
    if (_extractorFailures == 1) {
      _log('extractor failure: $detail; checking for a newer yt-dlp');
      unawaited(ensureTools(true));
    }
  }

  Future<yt.YtDlpOptions?> _ytdlpOptions() async {
    if (opts.skipTools) {
      return yt.YtDlpOptions(paths: yt.YtDlpPaths(ytdlp: 'yt-dlp', deno: null, ffmpeg: opts.ffmpegPath), sleepRequests: 0, log: _log);
    }
    final missing = await tools.verifyPresent(_toolPaths);
    if (missing != null) {
      await engine.recordIssue('tools', missing);
      _toolPaths = await tools.ensure(false);
    }
    final ytdlp = _toolPaths.ytdlp;
    if (ytdlp == null) return null;
    final s = engine.settings.current;
    return yt.YtDlpOptions(paths: yt.YtDlpPaths(ytdlp: ytdlp, deno: _toolPaths.deno, ffmpeg: opts.ffmpegPath), sleepRequests: (s.requestPauseMs / 1000).round(), log: _log, onExtractorFailure: _onExtractorFailure);
  }

  Future<IngestDeps?> _ingestDeps() async {
    final o = await _ytdlpOptions();
    if (o == null) return null;
    final impl = opts.ytdlp ?? YtDlpImpl();
    final ffmpeg = opts.ffmpegPath;
    return IngestDeps(
      resolve: (search, rejected) => (impl.resolveSearch ?? yt.resolveSearch)(o, search, rejected),
      inspect: (url) => (impl.inspect ?? yt.inspect)(o, url),
      download: (url, workdir) => (impl.downloadAudio ?? yt.downloadAudio)(o, url, workdir),
      clip: (src, dest, at) async {
        final r = await (opts.clipImpl ?? (s, d, a) => makeClip(ffmpeg, s, d, a))(src, dest, at);
        return (ok: r.ok, error: r.error);
      },
      measureRms: (src) async {
        final m = await (opts.measureRmsImpl ?? (s) => measureRms(ffmpeg, s))(src);
        return m == null ? null : RmsResult(rms: m.rms.toList(), hop: m.hop, duration: m.duration);
      },
      shouldStop: () => _cancelled || paused,
      log: _log,
    );
  }

  // ------------------------------------------------------------------ feed

  Future<void> checkFeed() async {
    final store = engine.store;
    if (store == null || !engine.isOpen) return;
    final base = engine.settings.current.feedBase;
    final nowIsoStr = _now().toUtc().toIso8601String();
    try {
      final reader = readerFor(base);
      final index = parseIndex(await reader.text('index.json'));
      final done = await ingestedRuns(store);
      final profile = await store.readOr('profile.json', <String, dynamic>{});
      final keepRuns = ((profile['retention'] as Map?)?['keep_runs'] as num?)?.toInt() ?? 8;
      final planned = planRuns(index, done, keepRuns, _now());
      var queued = 0;
      for (final pl in planned) {
        if (_queue.any((j) => j is _RunJob && j.run == pl.run)) continue;
        try {
          final parsed = parseRunFile(await reader.text(pl.file), expectRun: pl.run);
          await updateFeedState(store, (s) {
            final runs = (s['runs'] as Map).cast<String, dynamic>();
            final existing = (runs[pl.run] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
            runs[pl.run] = {...existing, 'state': existing['state'] == 'in-progress' ? 'in-progress' : 'queued', 'file': pl.file, 'count': parsed.candidates.length, 'audio': pl.audio, 'source': 'feed'};
          });
          _queue.add(_RunJob(run: pl.run, candidates: parsed.candidates, audio: pl.audio, source: 'feed'));
          queued++;
        } catch (e) {
          await engine.recordIssue('feed', 'Run ${pl.run} could not be read from the feed: $e');
        }
      }
      await updateFeedState(store, (s) {
        s['lastChecked'] = nowIsoStr;
        s['lastResult'] = queued > 0 ? '$queued run(s) queued' : 'up to date';
      });
      engine.feed = engine.feed.copyWith(lastChecked: nowIsoStr, lastResult: queued > 0 ? '$queued new' : 'up to date', archiveRuns: planned.where((x) => x.archive).length);
      await clearKind(store, 'feed');
    } on FeedError catch (e) {
      if (e.code == 'needs-newer-app') {
        await engine.recordIssue('feed', 'This feed needs a newer version of the app.');
      } else if (e.code == 'bad-index') {
        await engine.recordIssue('feed', 'The feed index could not be read: ${e.message}');
      } else {
        // Offline is normal: say when the feed was last checked and carry on.
        final state = await store.readOr('feed_state.json', emptyFeedState());
        engine.feed = engine.feed.copyWith(lastChecked: state['lastChecked'] as String?, lastResult: 'feed not reachable');
      }
    } catch (e) {
      await engine.recordIssue('feed', 'The feed check failed: $e');
    }
    await _scanPending();
    await engine.settings.update((c) => c.copyWith(feedCheckedAt: nowIsoStr));
    _updateFeedCounts();
    unawaited(_work());
  }

  /// Run files dropped into pending/, ordered by their run field.
  Future<void> _scanPending() async {
    final store = engine.store;
    final root = engine.libraryPath;
    if (store == null || root == null) return;
    final found = await pendingRunFiles(root);
    for (final b in found.bad) {
      await engine.recordIssue('pending', '${p.basename(b.path)} in pending/ could not be read and was left where it is (${b.error}).');
    }
    if (found.bad.isEmpty) await clearKind(store, 'pending');
    final done = await ingestedRuns(store);
    for (final f in found.ok) {
      if (_queue.any((j) => j is _RunJob && j.run == f.run)) continue;
      try {
        final parsed = parseRunFile(f.text, expectRun: f.run, source: CandidateSource.pending);
        if (done.contains(f.run)) {
          await archivePendingFile(f.path);
          continue;
        }
        await updateFeedState(store, (s) {
          final runs = (s['runs'] as Map).cast<String, dynamic>();
          final existing = (runs[f.run] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
          runs[f.run] = {...existing, 'state': existing['state'] == 'in-progress' ? 'in-progress' : 'queued', 'count': parsed.candidates.length, 'audio': true, 'source': 'pending'};
        });
        _queue.add(_RunJob(run: f.run, candidates: parsed.candidates, audio: true, source: 'pending', path: f.path));
      } catch (e) {
        await engine.recordIssue('pending', '${p.basename(f.path)} in pending/ could not be read and was left where it is ($e).');
      }
    }
  }

  void _updateFeedCounts() {
    final runs = _queue.whereType<_RunJob>().length;
    engine.feed = engine.feed.copyWith(runsWaiting: runs, queueLength: _queue.length);
    engine.push();
  }

  // ------------------------------------------------------------------ the queue

  void pause(bool value) {
    paused = value;
    final d = engine.feed.downloading;
    engine.feed = engine.feed.copyWith(downloading: d == null ? null : DownloadProgress(run: d.run, done: d.done, total: d.total, current: d.current, paused: value));
    engine.push();
    if (!value) unawaited(_work());
  }

  void cancel() {
    _cancelled = true;
    _queue.clear();
    _updateFeedCounts();
  }

  /// Try again / Get clip again for one track.
  Future<void> retryTrack(String id) async {
    if (!_queue.any((j) => j is _TrackJob && j.id == id)) _queue.add(_TrackJob(id));
    _updateFeedCounts();
    unawaited(_work());
  }

  Future<void> _retryNoAudio() async {
    final store = engine.store;
    if (store == null) return;
    final lib = Library(await store.readOr('library.json', Library.empty().json));
    for (final t in lib.tracks) {
      if (!t.clipPresent && (t.userSourceUrl != null || t.sourceUrl != null || ((t.artist ?? '').isNotEmpty && (t.title ?? '').isNotEmpty))) await retryTrack(t.id);
    }
  }

  Future<void> _work() async {
    if (_working || paused) return;
    _working = true;
    _cancelled = false;
    try {
      while (_queue.isNotEmpty && !_cancelled && !paused && engine.isOpen) {
        final job = _queue.first;
        if (job is _RunJob) {
          await _runJob(job);
        } else if (job is _TrackJob) {
          await _trackJob(job);
        }
        if (_queue.isNotEmpty && identical(_queue.first, job)) _queue.removeAt(0);
        _updateFeedCounts();
      }
    } finally {
      _working = false;
      engine.feed = engine.feed.copyWith(clearDownloading: true);
      _updateFeedCounts();
      kickPromote();
    }
  }

  Future<void> _runJob(_RunJob job) async {
    final store = engine.store;
    if (store == null) return;
    final deps = await _ingestDeps();
    if (deps == null) {
      await engine.recordIssue('tools', 'Downloads are waiting: the downloader (yt-dlp) is not installed yet. It is fetched automatically when the network is available.');
      _queue.remove(job);
      return;
    }
    await updateFeedState(store, (s) {
      final runs = (s['runs'] as Map).cast<String, dynamic>();
      final existing = (runs[job.run] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{'audio': job.audio, 'source': job.source};
      runs[job.run] = {...existing, 'state': 'in-progress', 'started': existing['started'] ?? _now().toUtc().toIso8601String()};
    });
    final settings = engine.settings.current;
    IngestResult? result;
    try {
      result = await runIngest(
        store,
        job.run,
        job.candidates,
        IngestDeps(
          resolve: deps.resolve,
          inspect: deps.inspect,
          download: deps.download,
          clip: deps.clip,
          measureRms: deps.measureRms,
          shouldStop: deps.shouldStop,
          log: deps.log,
          downloadAudio: job.audio,
          onProgress: (pr) {
            engine.feed = engine.feed.copyWith(
              clearDownloading: pr.phase == 'done' || pr.phase == 'stopped',
              downloading: pr.phase == 'done' || pr.phase == 'stopped' ? null : DownloadProgress(run: job.run, done: pr.done, total: pr.total, current: pr.current, paused: paused),
            );
            engine.push();
          },
        ),
        concurrency: settings.concurrency,
      );
    } catch (e) {
      await engine.recordIssue('ingest', 'Run ${job.run} stopped: $e');
      await updateFeedState(store, (s) {
        final runs = (s['runs'] as Map).cast<String, dynamic>();
        final existing = (runs[job.run] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{'audio': job.audio, 'source': job.source};
        runs[job.run] = {...existing, 'state': 'failed', 'error': '$e'};
      });
      return;
    }
    if (result.stopped) return; // stays in progress; resumes next time
    await updateFeedState(store, (s) {
      final runs = (s['runs'] as Map).cast<String, dynamic>();
      final existing = (runs[job.run] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{'audio': job.audio, 'source': job.source};
      runs[job.run] = {...existing, 'state': 'done', 'finished': _now().toUtc().toIso8601String()};
    });
    if (job.path != null) {
      try {
        await archivePendingFile(job.path!);
      } catch (_) {}
    }
    _runDone.add((run: job.run, result: result));
  }

  /// Re-fetch one track's clip, built from its own record: user link, then known source, then a fresh search.
  Future<void> _trackJob(_TrackJob job) async {
    final store = engine.store;
    if (store == null) return;
    final deps = await _ingestDeps();
    if (deps == null) return;
    final lib = Library(await store.readOr('library.json', Library.empty().json));
    final t = lib.find(job.id);
    if (t == null || (t.title ?? '').isEmpty) return;
    final cand = candidateFromTrack(t);
    final run = t.lastSeen ?? (t.runs.isNotEmpty ? t.runs.last : _now().toUtc().toIso8601String().substring(0, 10));
    try {
      final result = await runIngest(
        store,
        run,
        [cand],
        IngestDeps(
          resolve: deps.resolve,
          inspect: deps.inspect,
          download: deps.download,
          clip: deps.clip,
          measureRms: deps.measureRms,
          shouldStop: deps.shouldStop,
          log: deps.log,
          onProgress: (pr) {
            engine.feed = engine.feed.copyWith(clearDownloading: pr.phase == 'done' || pr.phase == 'stopped', downloading: pr.phase == 'done' || pr.phase == 'stopped' ? null : DownloadProgress(run: 'retry', done: pr.done, total: pr.total, current: pr.current, paused: paused));
            engine.push();
          },
        ),
        keepRuns: 0,
        skipPrune: true,
      );
      if (result.noAudio > 0) await engine.recordIssue('downloads', '${t.label}: still no audio${result.noMatch > 0 ? ' (no confident match)' : ''}.');
    } catch (e) {
      await engine.recordIssue('downloads', '${t.title}: $e');
    }
  }

  // ------------------------------------------------------------------ promotion

  void kickPromote() {
    if (_promoting) {
      _promoteAgain = true;
      return;
    }
    unawaited(_promoteLoop());
  }

  Future<void> _promoteLoop() async {
    final store = engine.store;
    if (store == null || _promoting) return;
    _promoting = true;
    try {
      do {
        _promoteAgain = false;
        final queue = await store.readOr('promote_queue.json', <String, dynamic>{'ids': <String>[]});
        final ids = ((queue['ids'] as List?) ?? const []).map((e) => e.toString()).toList();
        if (ids.isEmpty) break;
        final o = await _ytdlpOptions();
        if (o == null) break;
        final impl = opts.ytdlp ?? YtDlpImpl();
        final profile = await store.readOr('profile.json', <String, dynamic>{});
        final format = ((profile['promote'] as Map?)?['format'] ?? 'wav16').toString();
        await promoteMany(
          store,
          ids,
          format,
          PromoteDeps(
            download: (url, workdir) async => (await (impl.downloadFull ?? yt.downloadFull)(o, url, workdir))?.path,
            transcode: (src, dest, fmt) async {
              final r = await (opts.transcodeImpl ?? (s, d, f) => transcodeFull(opts.ffmpegPath, s, d, f))(src, dest, fmt);
              return (ok: r.ok, error: r.error);
            },
            log: _log,
          ),
          onProgress: (label, i, n) {
            engine.promoting = label;
            engine.push();
          },
          shouldStop: () => _cancelled,
        );
        engine.promoting = null;
        engine.push();
      } while (_promoteAgain);
    } catch (e) {
      await record(store, 'promote', false, 'Full-track download stopped: $e');
    } finally {
      _promoting = false;
      engine.promoting = null;
      engine.push();
    }
  }

  // ------------------------------------------------------------------ release check

  Future<void> checkForUpdate() async {
    final s = engine.settings.current;
    final last = s.updateCheckedAt == null ? null : DateTime.tryParse(s.updateCheckedAt!);
    if (last != null && _now().difference(last) < updateInterval) return;
    final r = await checkForNewerRelease(engine.version);
    await engine.settings.update((c) => c.copyWith(updateCheckedAt: _now().toUtc().toIso8601String()));
    engine.update = r == null ? null : UpdateInfo(version: r.version, url: r.url);
    engine.push();
  }
}

Candidate candidateFromTrack(Track t) {
  final c = Candidate(title: t.title ?? '', artist: t.artist ?? '');
  if (t.userSourceUrl != null) {
    c.sourceUrl = t.userSourceUrl;
  } else if (t.sourceUrl != null) {
    c.sourceUrl = t.sourceUrl;
  } else {
    c.search = '${t.artist ?? ''} ${t.title ?? ''}'.trim();
  }
  c.platform = t.platform;
  c.direction = t.direction;
  c.energy = t.energy;
  c.licence = t.licence;
  c.notes = t.notes;
  c.suits = t.suits;
  if (t.mood.isNotEmpty) c.mood = t.mood;
  c.uses = t.uses;
  c.bpm = t.bpm;
  return c;
}
