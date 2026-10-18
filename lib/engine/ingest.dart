/// Merge a run of candidates into the library. Port of ingest.ts (itself a port of ingest.py
/// with the changes the brief asks for): rows are filed as soon as the run starts (clip not yet
/// present) and clips fill in as they arrive; pruning happens once, when the run finishes; a run
/// interrupted by quitting resumes and skips clips already on disk; every failure is one health
/// line per run.
///
/// Nothing here talks to the network directly. `resolve`, `download` and `clip` are injected so
/// the runtime can wire yt-dlp and ffmpeg, and tests can use local files.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'health.dart';
import 'hook.dart';
import 'ids.dart';
import 'library.dart';
import 'store.dart';
import 'ytdlp.dart' show ResolvedUpload, DownloadedSource;

const trackFields = ['title', 'artist', 'platform', 'direction', 'uses', 'bpm', 'energy', 'mood', 'suits', 'profiles', 'licence', 'notes', 'source_url'];

class DryRunSummary {
  DryRunSummary({required this.run, required this.candidates, required this.fresh, required this.known, required this.keepRuns, required this.duplicateIds});
  final String run;
  final int candidates, fresh, known, keepRuns, duplicateIds;
}

/// Read-only: the same five numbers `ingest.py --dry-run` prints.
DryRunSummary dryRun(Library library, List<Candidate> candidates, String run, int keepRuns) {
  final known = library.ids;
  final ids = candidates.map((c) => slugify(c.artist, c.title)).toList();
  final fresh = ids.where((i) => !known.contains(i)).length;
  return DryRunSummary(run: run, candidates: candidates.length, fresh: fresh, known: candidates.length - fresh, keepRuns: keepRuns, duplicateIds: ids.length - ids.toSet().length);
}

bool _isEmptyValue(Object? v) => v == null || v == '' || (v is List && v.isEmpty);

/// ingest.merge: file or update one track's metadata row. Clip and hook fields are optional.
Track mergeTrack(Library library, Candidate cand, String trackId, String runStamp, String? clipRel, int clipBytes, [HookResult? hook]) {
  var rec = library.find(trackId);
  rec ??= library.add(Track.create(id: trackId, firstSeen: runStamp));
  final fields = cand.trackFields;
  for (final field in trackFields) {
    final v = fields[field];
    if (_isEmptyValue(v)) continue;
    // A link the user set by hand is never overwritten by a later feed run.
    if (field == 'source_url' && rec.userSourceUrl != null) continue;
    rec.set(field, v is List ? List<String>.from(v) : v);
  }
  rec.json.putIfAbsent('mood', () => <String>[]);
  rec.json.putIfAbsent('profiles', () => <String>[]);
  rec.json.putIfAbsent('licence', () => 'platform');
  rec.set('last_seen', runStamp);
  if (!rec.runs.contains(runStamp)) {
    final runs = {...rec.runs, runStamp}.toList()..sort();
    rec.set('runs', runs.length > 24 ? runs.sublist(runs.length - 24) : runs);
  }
  if (cand.uses != null) {
    final hist = ((rec.json['uses_history'] ??= <String, dynamic>{}) as Map).cast<String, dynamic>();
    hist[runStamp] = cand.uses;
    final keys = hist.keys.toList()..sort();
    for (final stale in keys.take(keys.length > 24 ? keys.length - 24 : 0)) {
      hist.remove(stale);
    }
    rec.json['uses_history'] = hist;
  }
  if (clipRel != null) {
    rec.set('clip', clipRel);
    rec.set('clip_present', true);
    rec.set('clip_bytes', clipBytes);
  }
  if (hook != null) {
    rec.set('hook_at', (hook.at * 10).round() / 10);
    rec.set('hook_method', hook.method);
    rec.set('hook_detail', hook.detail);
  }
  if (cand.pin) rec.set('pinned', true);
  return rec;
}

/// ingest.prune: keep a clip if the track is pinned, a favourite, seen in one of the last
/// `keepRuns` dated runs, or seen in the run just ingested. Only ever sweeps `<known-id>.mp3`.
Future<({int kept, int freed})> prune(Library library, String root, Set<String> favourites, int keepRuns, String? currentRun) async {
  final dated = library.tracks.expand((t) => t.runs).where(validRunStamp).toSet().toList()..sort();
  final recent = <String>{...(keepRuns > 0 ? dated.skip(dated.length > keepRuns ? dated.length - keepRuns : 0) : const <String>[])};
  if (currentRun != null) recent.add(currentRun);
  final knownIds = library.ids;
  var freed = 0, kept = 0;
  for (final track in library.tracks) {
    if (!track.clipPresent || track.clip == null) continue;
    if (track.pinned || favourites.contains(track.id) || track.runs.any(recent.contains)) {
      kept++;
      continue;
    }
    final clipPath = File(p.join(root, track.clip!));
    if (await clipPath.exists()) {
      freed += await clipPath.length();
      await clipPath.delete();
    }
    track.set('clip_present', false);
    track.remove('clip_bytes');
  }
  final referenced = library.tracks.where((t) => t.clipPresent && t.clip != null).map((t) => p.basename(t.clip!)).toSet();
  final clipsDir = Directory(p.join(root, 'clips'));
  if (await clipsDir.exists()) {
    await for (final e in clipsDir.list()) {
      if (e is! File || p.extension(e.path) != '.mp3') continue;
      final name = p.basename(e.path);
      final stem = name.substring(0, name.length - 4);
      if (knownIds.contains(stem) && !referenced.contains(name)) {
        freed += await e.length();
        await e.delete();
      }
    }
  }
  return (kept: kept, freed: freed);
}

// ------------------------------------------------------------------ the run itself

class IngestProgress {
  IngestProgress({required this.run, required this.total, required this.done, this.current, required this.phase});
  final String run;
  final int total, done;
  final String? current;
  final String phase; // filing | downloading | pruning | done | stopped
}

class IngestResult {
  IngestResult({required this.run, required this.added, required this.updated, required this.noAudio, required this.rejected, required this.clipsKept, required this.bytesFreed, required this.tracked, required this.finished, this.stopped = false, this.noMatch = 0});
  final String run;
  final int added, updated, noAudio, rejected, clipsKept, bytesFreed, tracked, noMatch;
  final String finished;
  final bool stopped;

  /// last_run.json in the Python's shape.
  Json toJson() => <String, dynamic>{
        'run': run,
        'ok': true,
        'added': added,
        'updated': updated,
        'no_audio': noAudio,
        'rejected': rejected,
        'clips_kept': clipsKept,
        'bytes_freed': bytesFreed,
        'tracked': tracked,
        'finished': finished,
        if (noMatch > 0) 'no_match': noMatch,
        if (stopped) 'stopped': true,
      };
}

class IngestDeps {
  IngestDeps({
    required this.resolve,
    required this.inspect,
    required this.download,
    required this.clip,
    this.measureRms,
    this.pause = Duration.zero,
    this.onProgress,
    this.shouldStop,
    this.downloadAudio = true,
    this.log,
  });

  /// "artist title" → the first search result that is not in `rejected`.
  final Future<ResolvedUpload?> Function(String search, List<String> rejected) resolve;
  final Future<ResolvedUpload?> Function(String url) inspect;
  final Future<DownloadedSource?> Function(String url, String workdir) download;
  final Future<({bool ok, String? error})> Function(String src, String dest, double hookStart) clip;
  final Future<RmsResult?> Function(String src)? measureRms;
  final Duration pause;
  final void Function(IngestProgress p)? onProgress;
  final bool Function()? shouldStop;
  final bool downloadAudio;
  final void Function(String line)? log;
}

/// The match transparency rule: the upload's title or channel must contain the candidate's title or artist.
bool confidentMatch({required String uploadTitle, required String uploadChannel, required String title, required String artist}) {
  String norm(String s) => s.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').toLowerCase().trim();
  final hay = '${norm(uploadTitle)} | ${norm(uploadChannel)}';
  final t = norm(title);
  final a = norm(artist);
  final core = t.replaceAll(RegExp(r'\b(feat|ft|remix|remastered|version|official|video|audio|lyrics)\b'), '').trim();
  return [t, core, a].any((s) => s.length >= 2 && hay.contains(s));
}

class _Planned {
  _Planned(this.cand, this.id, this.label, this.clipRel, this.clipPath);
  final Candidate cand;
  final String id, label, clipRel, clipPath;
}

/// Run one ingest. `candidates` are already normalised. Resumable: clips already on disk are
/// skipped, so re-running after a quit picks up where it left off without duplicates.
Future<IngestResult> runIngest(Store store, String run, List<Candidate> candidates, IngestDeps deps, {int? keepRuns, String? workRoot, int concurrency = 1, bool skipPrune = false}) async {
  final root = store.root;
  final log = deps.log ?? (String _) {};
  await Directory(p.join(root, 'clips')).create(recursive: true);

  final profile = await store.readOr('profile.json', <String, dynamic>{});
  final keep = keepRuns ?? ((profile['retention'] as Map?)?['keep_runs'] as num?)?.toInt() ?? 2;

  // 1. Dedupe within the run and file every row straight away.
  final rejected = <String>[];
  final seen = <String, String>{};
  final planned = <_Planned>[];
  for (final cand in candidates) {
    final id = slugify(cand.artist, cand.title);
    final label = cand.label;
    if (seen.containsKey(id)) {
      log('! duplicate of ${seen[id]} within this run: $label — skipped');
      rejected.add('$label (duplicate of ${seen[id]})');
      continue;
    }
    seen[id] = label;
    planned.add(_Planned(cand, id, label, 'clips/$id.mp3', p.join(root, 'clips', '$id.mp3')));
  }
  void progress(String phase, int done, [String? current]) => deps.onProgress?.call(IngestProgress(run: run, total: planned.length, done: done, current: current, phase: phase));
  progress('filing', 0);

  final known = <String>{};
  await store.update('library.json', Library.empty().json, (json) {
    final library = Library(json);
    known.addAll(library.ids);
    for (final pl in planned) {
      mergeTrack(library, pl.cand, pl.id, run, null, 0);
    }
    library.lastRun = newerStamp(library.lastRun, run);
    library.updated = nowIso();
    return library.json;
  });

  // 2. Audio, a few tracks at a time, filling in rows as clips arrive.
  final work = Directory(workRoot ?? p.join(root, '.work-$pid'));
  if (await work.exists()) await work.delete(recursive: true);
  await work.create(recursive: true);

  var done = 0, noAudio = 0, noMatch = 0;
  final reasons = <String, int>{};
  var stopped = false;
  final outcomes = <String, bool>{};
  final pool = concurrency.clamp(1, 3);

  Future<void> processOne(_Planned pl) async {
    final existing = File(pl.clipPath);
    if (await existing.exists() && await existing.length() > 0) {
      final size = await existing.length();
      await store.update('library.json', Library.empty().json, (json) {
        final library = Library(json);
        mergeTrack(library, pl.cand, pl.id, run, pl.clipRel, size);
        library.updated = nowIso();
        return library.json;
      });
      outcomes[pl.id] = true;
      return;
    }
    if (!deps.downloadAudio) {
      outcomes[pl.id] = false;
      return;
    }
    final workdir = Directory(p.join(work.path, pl.id));
    await workdir.create(recursive: true);
    var got = false;
    HookResult? hook;
    Json? match;
    String? matchUrl;
    var matchStatus = 'no-source';
    String? reason;
    try {
      final current = Library(await store.readOr('library.json', Library.empty().json));
      final row = current.find(pl.id);
      final src = await _fetchSource(pl.cand, row, workdir.path, deps, log);
      matchStatus = src.status;
      match = src.match;
      matchUrl = src.url;
      reason = src.reason;
      if (src.file != null) {
        final explicit = pl.cand.hookStart != null ? parseTs(pl.cand.hookStart) : null;
        hook = await detect(
          info: src.file!.info,
          explicit: explicit,
          measureRms: deps.measureRms == null ? null : () => deps.measureRms!(src.file!.path),
        );
        log('  · hook at ${hook.at}s (${hook.method}: ${hook.detail})');
        final r = await deps.clip(src.file!.path, pl.clipPath, hook.at);
        got = r.ok;
        if (!r.ok) {
          log('  ! transcode failed: ${r.error ?? ''}');
          reason = 'clip could not be made: ${r.error ?? 'ffmpeg failed'}';
        }
      }
    } finally {
      if (await workdir.exists()) await workdir.delete(recursive: true);
    }
    final size = got ? await File(pl.clipPath).length() : 0;
    await store.update('library.json', Library.empty().json, (json) {
      final library = Library(json);
      final rec = mergeTrack(library, pl.cand, pl.id, run, got ? pl.clipRel : null, size, got ? hook : null);
      if (match != null) {
        rec.set('match', match);
        rec.set('match_status', rec.userSourceUrl != null ? 'user-link' : 'matched');
        if (matchUrl != null && rec.userSourceUrl == null) rec.set('source_url', matchUrl);
      } else if (matchStatus == 'no-confident-match') {
        rec.set('match_status', 'no-confident-match');
      }
      if (got) {
        rec.remove('audio_error');
      } else if (reason != null) {
        rec.set('audio_error', reason);
      }
      library.updated = nowIso();
      return library.json;
    });
    if (!got) {
      noAudio++;
      if (matchStatus == 'no-confident-match') noMatch++;
      if (reason != null) reasons[reason] = (reasons[reason] ?? 0) + 1;
    }
    outcomes[pl.id] = got;
    if (deps.pause > Duration.zero) await Future<void>.delayed(deps.pause);
  }

  try {
    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (deps.shouldStop?.call() == true) {
          stopped = true;
          return;
        }
        if (next >= planned.length) return;
        final pl = planned[next++];
        progress('downloading', done, pl.label);
        await processOne(pl);
        done++;
        progress('downloading', done, pl.label);
      }
    }

    await Future.wait(List.generate(pool, (_) => worker()));
    if (!stopped && deps.shouldStop?.call() == true) stopped = true;
    if (done >= planned.length) stopped = false;
  } finally {
    if (await work.exists()) await work.delete(recursive: true);
  }

  // 3. Prune once, when the run finishes. A stopped run stays in progress and is not pruned.
  var kept = 0, freed = 0, tracked = 0;
  final added = planned.where((pl) => !known.contains(pl.id) && outcomes[pl.id] == true).length;
  final updated = planned.where((pl) => known.contains(pl.id) && outcomes[pl.id] == true).length;
  if (!stopped && !skipPrune) {
    progress('pruning', done);
    await store.withLock(() async {
      final library = Library(await store.readOr('library.json', Library.empty().json));
      final favourites = Favourites(await store.readOr('favourites.json', Favourites.empty().json)).ids.toSet();
      final r = await prune(library, root, favourites, keep, run);
      kept = r.kept;
      freed = r.freed;
      tracked = library.tracks.length;
      library.updated = nowIso();
      await store.writeUnlocked('library.json', library.json);
    });
  } else {
    tracked = Library(await store.readOr('library.json', Library.empty().json)).tracks.length;
  }
  final writeSummary = !stopped && !skipPrune;

  final result = IngestResult(run: run, added: added, updated: updated, noAudio: noAudio, rejected: rejected.length, clipsKept: kept, bytesFreed: freed, tracked: tracked, finished: nowIso(), stopped: stopped, noMatch: noMatch);
  if (writeSummary) {
    await store.write('last_run.json', result.toJson());
    final attempted = added + updated + noAudio;
    final why = commonReason(reasons);
    if (noAudio > 0 && added + updated == 0) {
      await record(store, 'ingest', false, 'Run $run downloaded nothing: $noAudio tracks had no audio.', why ?? 'Usually the downloader needs updating, or there is no network.');
    } else if (noAudio > 0) {
      await record(store, 'ingest', false, 'Run $run: $noAudio of $attempted had no audio${noMatch > 0 ? ' ($noMatch with no confident match)' : ''}.', why ?? '');
    } else {
      await clearKind(store, 'ingest');
    }
  }
  progress(stopped ? 'stopped' : 'done', done);
  return result;
}

/// "Most common reason: ... (n of m)" for the health line, or null when nothing was recorded.
String? commonReason(Map<String, int> reasons) {
  if (reasons.isEmpty) return null;
  final total = reasons.values.fold(0, (a, b) => a + b);
  final top = reasons.entries.reduce((a, b) => b.value > a.value ? b : a);
  return 'Most common reason: ${top.key} (${top.value} of $total).';
}

/// Thrown by a resolve or download step that knows why it failed; the reason is kept on the track.
class SourceFailure implements Exception {
  SourceFailure(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

class _Source {
  _Source({this.file, this.match, this.url, required this.status, this.reason});
  final DownloadedSource? file;
  final Json? match;
  final String? url;
  final String status; // matched | no-confident-match | no-source | download-failed | local-missing
  final String? reason;
}

Future<_Source> _fetchSource(Candidate cand, Track? row, String workdir, IngestDeps deps, void Function(String) log) async {
  if (cand.local != null) {
    if (await File(cand.local!).exists()) return _Source(file: DownloadedSource(path: cand.local!), status: 'matched');
    log('  ! local file missing: ${cand.local}');
    return _Source(status: 'local-missing', reason: 'local file missing: ${cand.local}');
  }
  // A link the user set wins over everything, then the row's known source, then the candidate's.
  var url = row?.userSourceUrl ?? row?.sourceUrl ?? cand.sourceUrl;
  ResolvedUpload? upload;
  if (url == null && cand.search != null) {
    try {
      upload = await deps.resolve(cand.search!, row?.rejectedVideoIds ?? const []);
    } on SourceFailure catch (e) {
      log('  · search failed for ${cand.search}: ${e.reason}');
      return _Source(status: 'no-source', reason: e.reason);
    }
    if (upload == null) {
      log('  · search found nothing for ${cand.search}');
      return _Source(status: 'no-source', reason: 'search found nothing');
    }
    if (!confidentMatch(uploadTitle: upload.title, uploadChannel: upload.channel, title: cand.title, artist: cand.artist)) {
      log('  · no confident match: "${upload.title}" by ${upload.channel}');
      return _Source(status: 'no-confident-match', reason: 'best result was "${upload.title}" by ${upload.channel}');
    }
    url = upload.url;
  }
  if (url == null) {
    log('  · no source_url or search — filing metadata only');
    return _Source(status: 'no-source');
  }
  final DownloadedSource? file;
  try {
    file = await deps.download(url, workdir);
  } on SourceFailure catch (e) {
    return _Source(status: 'download-failed', reason: e.reason);
  }
  if (file == null) return _Source(status: 'download-failed', reason: 'download failed');
  final info = file.info ?? const <String, dynamic>{};
  final match = <String, dynamic>{
    'video_id': upload?.videoId ?? (info['id'] ?? '').toString(),
    'title': upload?.title ?? (info['title'] ?? '').toString(),
    'channel': upload?.channel ?? (info['channel'] ?? info['uploader'] ?? '').toString(),
    'duration': upload?.duration ?? (info['duration'] is num ? info['duration'] : null),
  };
  return _Source(file: file, match: match, url: url, status: 'matched');
}
