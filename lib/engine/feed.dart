/// The feed client (replaces catchup.py). Reads index.json from an https base or a local folder,
/// keeps feed_state.json in the library, decides which runs to ingest and whether to download
/// audio for them, and picks up run files dropped into pending/.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'library.dart';
import 'settings.dart';
import 'store.dart';

const feedVersion = 1;
const archiveDays = 21;

class FeedIndexRun {
  FeedIndexRun({required this.run, required this.file, this.count});
  final String run, file;
  final int? count;
}

class FeedIndex {
  FeedIndex({required this.version, this.updated, required this.runs});
  final int version;
  final String? updated;
  final List<FeedIndexRun> runs;
}

class FeedError implements Exception {
  FeedError(this.message, this.code); // unreachable | bad-index | needs-newer-app | bad-run
  final String message, code;
  @override
  String toString() => message;
}

abstract class FeedReader {
  Future<String> text(String relativePath);
}

/// Reads feed files from an https base URL.
class HttpReader implements FeedReader {
  HttpReader(this.base, {http.Client? client}) : _client = client ?? http.Client();
  final String base;
  final http.Client _client;

  @override
  Future<String> text(String rel) async {
    final url = Uri.parse(base).resolve(rel);
    http.Response res;
    try {
      res = await _client.get(url, headers: const {'Cache-Control': 'no-cache'}).timeout(const Duration(seconds: 30));
    } catch (e) {
      throw FeedError('Could not reach the feed ($e)', 'unreachable');
    }
    if (res.statusCode != 200) throw FeedError('The feed answered ${res.statusCode} for $rel', 'unreachable');
    return utf8.decode(res.bodyBytes);
  }
}

/// Reads feed files from a local folder (tests, or a feed copied by hand).
class FolderReader implements FeedReader {
  FolderReader(this.dir);
  final String dir;
  @override
  Future<String> text(String rel) async {
    final safe = rel.split('/').where((s) => s.isNotEmpty && s != '..' && s != '.').toList();
    try {
      return await File(p.joinAll([dir, ...safe])).readAsString();
    } catch (e) {
      throw FeedError('Could not read $rel from the feed folder', 'unreachable');
    }
  }
}

FeedReader readerFor(String base, {http.Client? client}) => isHttpFeed(base) ? HttpReader(base, client: client) : FolderReader(base);

FeedIndex parseIndex(String text) {
  Object? data;
  try {
    data = jsonDecode(text);
  } catch (_) {
    throw FeedError('The feed index is not valid JSON', 'bad-index');
  }
  if (data is! Map || data['runs'] is! List) throw FeedError('The feed index has no runs list', 'bad-index');
  final version = (data['version'] as num?)?.toInt() ?? 1;
  if (version > feedVersion) throw FeedError('This feed needs a newer version of the app.', 'needs-newer-app');
  final runs = <FeedIndexRun>[];
  for (final r in data['runs'] as List) {
    if (r is! Map || !validRunStamp(r['run']) || r['file'] is! String) continue;
    runs.add(FeedIndexRun(run: r['run'] as String, file: r['file'] as String, count: (r['count'] as num?)?.toInt()));
  }
  // Sort by date ourselves; never trust the feed's order.
  runs.sort((a, b) => a.run.compareTo(b.run));
  return FeedIndex(version: version, updated: data['updated'] as String?, runs: runs);
}

class ParsedRun {
  ParsedRun({required this.run, required this.candidates, required this.rejected});
  final String run;
  final List<Candidate> candidates;
  final List<String> rejected;
}

ParsedRun parseRunFile(String text, {String? expectRun, CandidateSource source = CandidateSource.feed}) {
  Object? data;
  try {
    data = jsonDecode(text);
  } catch (_) {
    throw FeedError('The run file is not valid JSON', 'bad-run');
  }
  String? run;
  List raw;
  if (data is List) {
    raw = data;
    run = expectRun;
  } else if (data is Map) {
    run = data['run'] is String ? data['run'] as String : expectRun;
    raw = data['candidates'] is List ? data['candidates'] as List : const [];
  } else {
    throw FeedError('The run file is not a run', 'bad-run');
  }
  if (!validRunStamp(run)) throw FeedError('The run file has no YYYY-MM-DD run date', 'bad-run');
  final candidates = <Candidate>[];
  final rejected = <String>[];
  for (final r in raw) {
    final c = normalizeCandidate(r is Map ? r : const {}, source);
    if (c is Rejected) {
      rejected.add(c.reason);
    } else {
      candidates.add(c as Candidate);
    }
  }
  return ParsedRun(run: run!, candidates: candidates, rejected: rejected);
}

/// Runs already handled: done in feed_state.json, or any track in library.json carries the date.
Future<Set<String>> ingestedRuns(Store store) async {
  final state = await store.readOr('feed_state.json', emptyFeedState());
  final done = <String>{};
  for (final e in ((state['runs'] as Map?) ?? const {}).entries) {
    if ((e.value as Map?)?['state'] == 'done') done.add(e.key.toString());
  }
  final library = Library(await store.readOr('library.json', Library.empty().json));
  for (final t in library.tracks) {
    for (final r in t.runs) {
      if (validRunStamp(r)) done.add(r);
    }
  }
  return done;
}

Json emptyFeedState() => <String, dynamic>{'version': 1, 'runs': <String, dynamic>{}};

class PlannedRun {
  PlannedRun({required this.run, required this.file, this.count, required this.audio, required this.archive});
  final String run, file;
  final int? count;
  final bool audio, archive;
}

int ageDays(String run, [DateTime? today]) {
  final t = DateTime.parse('${run}T00:00:00Z');
  return (today ?? DateTime.now()).toUtc().difference(t).inDays;
}

/// Which runs to ingest, oldest first, and which get audio: the newest `keepRuns` runs in the
/// whole index (so a first launch never downloads the history). Done runs are skipped.
List<PlannedRun> planRuns(FeedIndex index, Set<String> done, int keepRuns, [DateTime? today]) {
  final all = index.runs;
  final withAudio = all.skip(all.length > keepRuns ? all.length - keepRuns : 0).map((r) => r.run).toSet();
  if (keepRuns <= 0) withAudio.clear();
  return [
    for (final r in all)
      if (!done.contains(r.run)) PlannedRun(run: r.run, file: r.file, count: r.count, audio: withAudio.contains(r.run), archive: ageDays(r.run, today) > archiveDays),
  ];
}

class PendingFile {
  PendingFile({required this.path, required this.run, required this.text});
  final String path, run, text;
}

/// Run files the user dropped into pending/, ordered by their `run` field, not their file name.
Future<({List<PendingFile> ok, List<({String path, String error})> bad})> pendingRunFiles(String libraryRoot) async {
  final dir = Directory(p.join(libraryRoot, 'pending'));
  final names = <String>[];
  if (await dir.exists()) {
    await for (final e in dir.list()) {
      if (e is File && p.basename(e.path).toLowerCase().endsWith('.json')) names.add(e.path);
    }
  }
  names.sort();
  final ok = <PendingFile>[];
  final bad = <({String path, String error})>[];
  for (final path in names) {
    try {
      final text = await File(path).readAsString();
      final parsed = jsonDecode(text);
      final run = parsed is List ? p.basename(path).replaceAll(RegExp(r'\.json$', caseSensitive: false), '') : (parsed is Map ? parsed['run'] : null);
      if (!validRunStamp(run)) throw const FormatException('no YYYY-MM-DD run date');
      ok.add(PendingFile(path: path, run: run as String, text: text));
    } catch (e) {
      bad.add((path: path, error: e is FormatException ? e.message : e.toString()));
    }
  }
  ok.sort((a, b) => a.run.compareTo(b.run));
  return (ok: ok, bad: bad);
}

/// After a successful ingest, move the dropped file to pending/ingested/ (never overwrite).
Future<void> archivePendingFile(String path) async {
  final dir = Directory(p.join(p.dirname(path), 'ingested'));
  await dir.create(recursive: true);
  var dest = p.join(dir.path, p.basename(path));
  if (await File(dest).exists()) {
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[-:T]'), '').substring(8, 14);
    dest = p.join(dir.path, p.basename(path).replaceAll(RegExp(r'\.json$', caseSensitive: false), '-$stamp.json'));
  }
  await File(path).rename(dest);
}

Future<Json> updateFeedState(Store store, void Function(Json state) fn) => store.update('feed_state.json', emptyFeedState(), (s) {
      s.putIfAbsent('runs', () => <String, dynamic>{});
      fn(s);
      return s;
    });
