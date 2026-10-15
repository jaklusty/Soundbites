import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:soundbites/engine/feed.dart';
import 'package:soundbites/engine/library.dart';
import 'package:soundbites/engine/runtime.dart';
import 'package:soundbites/engine/store.dart';

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('sb-feed-'));
  tearDown(() => root.delete(recursive: true));

  test('parses, sorts by date, and refuses a newer feed version', () {
    final idx = parseIndex('{"version":1,"runs":[{"run":"2026-10-08","file":"runs/2026-10-08.json","count":15},{"run":"2026-09-21","file":"runs/2026-09-21.json"},{"run":"junk","file":"x"}]}');
    expect(idx.runs.map((r) => r.run), ['2026-09-21', '2026-10-08']);
    expect(() => parseIndex('{"version":2,"runs":[]}'), throwsA(predicate((e) => e is FeedError && e.code == 'needs-newer-app')));
    expect(() => parseIndex('nope'), throwsA(isA<FeedError>()));
    expect(() => parseIndex('{}'), throwsA(predicate((e) => e is FeedError && e.message.contains('no runs'))));
  });

  test('parses the real feed files (snapshot of 10 October 2026)', () async {
    final reader = FolderReader(p.join('test', 'fixtures', 'feed'));
    final idx = parseIndex(await reader.text('index.json'));
    expect(idx.runs.length, greaterThanOrEqualTo(6));
    final run = parseRunFile(await reader.text(idx.runs.first.file), expectRun: idx.runs.first.run);
    expect(run.run, '2026-09-21');
    expect(run.candidates.length, 14);
    expect(run.candidates.first.title, 'Glue');
    expect(run.candidates.first.artist, 'Bicep');
    expect(run.candidates.first.search, 'Bicep Glue');
    expect(run.candidates.first.mood, isA<List<String>>());
    expect(run.candidates.first.suits, isA<String>());
  });

  test('plans oldest first, audio only for the newest keep_runs, skipping done runs', () {
    final runs = ['2026-09-01', '2026-09-10', '2026-09-20', '2026-10-05'].map((r) => '{"run":"$r","file":"runs/$r.json"}').join(',');
    final idx = parseIndex('{"version":1,"runs":[$runs]}');
    final planned = planRuns(idx, {'2026-09-10'}, 2, DateTime.utc(2026, 10, 10));
    expect(planned.map((x) => [x.run, x.audio, x.archive]).toList(), [
      ['2026-09-01', false, true],
      ['2026-09-20', true, false],
      ['2026-10-05', true, false],
    ]);
    expect(ageDays('2026-09-19', DateTime.utc(2026, 10, 10, 12)), 21);
  });

  test('done runs come from feed_state.json and from track runs', () async {
    final store = Store(root.path);
    await store.write('feed_state.json', {'version': 1, 'runs': {'2026-09-01': {'state': 'done'}, '2026-09-05': {'state': 'failed'}}});
    await store.write('library.json', {'version': 1, 'tracks': [{'id': 'a', 'runs': ['2026-09-10', 'junk']}]});
    expect((await ingestedRuns(store)).toList()..sort(), ['2026-09-01', '2026-09-10']);
  });

  test('pending files are ordered by their run field and bad ones are left alone', () async {
    final pending = Directory(p.join(root.path, 'pending'))..createSync();
    await File(p.join(pending.path, 'a-later.json')).writeAsString('{"run":"2026-10-05","candidates":[]}');
    await File(p.join(pending.path, 'b-earlier.json')).writeAsString('{"run":"2026-09-01","candidates":[]}');
    await File(p.join(pending.path, 'broken.json')).writeAsString('{');
    await File(p.join(pending.path, 'nodate.json')).writeAsString('{"candidates":[]}');
    final r = await pendingRunFiles(root.path);
    expect(r.ok.map((f) => f.run), ['2026-09-01', '2026-10-05']);
    expect(r.bad.map((b) => p.basename(b.path)), ['broken.json', 'nodate.json']);
    await archivePendingFile(r.ok.first.path);
    await File(p.join(pending.path, 'b-earlier.json')).writeAsString('{"run":"2026-09-01","candidates":[]}');
    await archivePendingFile(p.join(pending.path, 'b-earlier.json'));
    expect(Directory(p.join(pending.path, 'ingested')).listSync().length, 2);
    final left = pending.listSync().whereType<File>().map((e) => p.basename(e.path)).toList();
    expect(left, containsAll(['broken.json', 'nodate.json', 'a-later.json']));
  });

  test('rebuilds a candidate from a track record', () {
    final c = candidateFromTrack(Track({'id': 'x', 'title': 'Glue', 'artist': 'Bicep', 'mood': ['a']}));
    expect([c.title, c.artist, c.search, c.mood], ['Glue', 'Bicep', 'Bicep Glue', ['a']]);
    expect(candidateFromTrack(Track({'id': 'x', 'title': 'Glue', 'artist': 'Bicep', 'source_url': 'https://a', 'user_source_url': 'https://b'})).sourceUrl, 'https://b');
  });
}
