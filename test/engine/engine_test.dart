import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:soundbites/engine/engine.dart';
import 'package:soundbites/engine/library_open.dart';
import 'package:soundbites/engine/state.dart';
import 'package:soundbites/engine/store.dart';

void main() {
  late String base, appData, lib;
  setUp(() async {
    base = (await Directory.systemTemp.createTemp('sb-engine-')).path;
    appData = p.join(base, 'appdata');
    lib = p.join(base, 'lib');
    await Directory(appData).create();
    await Directory(lib).create();
  });
  tearDown(() => Directory(base).delete(recursive: true));

  Engine engine() => Engine(appDataDir: appData, version: '0.0.0-test');
  Future<List<String>> names(String dir) async => (await Directory(dir).list().map((e) => p.basename(e.path)).toList())..sort();

  test('first launch has no library; an empty folder is reported, never auto-created', () async {
    final e = engine();
    await e.start();
    expect((await e.snapshot()).library.status, LibraryStatus.none);
    expect((await e.open(lib)).status, LibraryStatus.empty);
    expect(await names(lib), isEmpty);
    expect((await e.createHere(lib)).status, LibraryStatus.open);
    expect(await names(lib), contains('library.json'));
    await e.close();
  });

  test('a missing remembered folder is reported and nothing is created', () async {
    final e = engine();
    await e.settings.load();
    await e.settings.update((s) => s.copyWith(libraryPath: p.join(base, 'unplugged')));
    await e.start();
    expect((await e.snapshot()).library.status, LibraryStatus.missing);
    expect(await Directory(p.join(base, 'unplugged')).exists(), isFalse);
    await e.close();
  });

  test('a star survives a restart and queues the full track once', () async {
    await createLibrary(lib);
    await Store(lib).update('library.json', {'version': 1, 'tracks': []}, (l) {
      (l['tracks'] as List).add({'id': 'abc', 'first_seen': '2026-10-10', 'runs': ['2026-10-10'], 'clip': null, 'clip_present': false, 'title': 'A', 'artist': 'B'});
      return l;
    });
    var e = engine();
    await e.start();
    await e.open(lib);
    expect(await e.star('abc', true), isTrue);
    expect(await e.star('abc', true), isFalse);
    var s = await e.snapshot();
    expect(s.favourites, {'abc'});
    expect(s.promoteQueue, ['abc']);
    await e.close();

    e = engine();
    await e.start();
    s = await e.snapshot();
    expect(s.library.status, LibraryStatus.open);
    expect(s.favourites, {'abc'});
    await e.star('abc', false);
    expect((await e.snapshot()).favourites, isEmpty);
    expect(() => e.star('nope', true), throwsA(predicate((x) => x.toString().contains('No such track'))));
    await e.close();
  });

  test('the library lock blocks a second engine and offers take-over when stale', () async {
    await createLibrary(lib);
    final a = engine();
    await a.open(lib);
    final b = Engine(appDataDir: p.join(base, 'appdata2'), version: 'x');
    expect((await b.open(lib)).status, LibraryStatus.held);
    await a.close();
    await Directory(p.join(lib, 'soundbites.lock')).create();
    await File(p.join(lib, 'soundbites.lock', 'owner.json')).writeAsString(jsonEncode({'host': 'other', 'user': 'u', 'pid': 1, 'app': 'Soundbites', 'started': '2026-01-01T00:00:00Z', 'heartbeat': '2026-01-01T00:00:00Z'}));
    expect((await b.open(lib)).status, LibraryStatus.stale);
    expect((await b.takeOver()).status, LibraryStatus.open);
    await b.close();
  });

  test('wrong track removes the clip, remembers the video id, and a pasted link sticks', () async {
    await createLibrary(lib);
    await File(p.join(lib, 'clips', 'abc.mp3')).writeAsString('x');
    await Store(lib).update('library.json', {'version': 1, 'tracks': []}, (l) {
      (l['tracks'] as List).add({'id': 'abc', 'first_seen': '2026-10-10', 'runs': ['2026-10-10'], 'clip': 'clips/abc.mp3', 'clip_present': true, 'title': 'A', 'artist': 'B', 'source_url': 'https://www.youtube.com/watch?v=u5Ee8QrWyhc', 'match': {'video_id': 'u5Ee8QrWyhc', 'title': 'x', 'channel': 'y', 'duration': 1}});
      return l;
    });
    final e = engine();
    await e.open(lib);
    final t = await e.rejectMatch('abc', false);
    expect(t!.clipPresent, isFalse);
    expect(t.rejectedVideoIds, ['u5Ee8QrWyhc']);
    expect(t.sourceUrl, isNull);
    expect(await names(p.join(lib, 'clips')), isEmpty);
    await File(p.join(lib, 'clips', 'abc.mp3')).writeAsString('old clip');
    await e.setTrackLink('abc', 'https://youtu.be/abcdefghijk');
    final row = (await e.snapshot()).tracks.first;
    expect([row.userSourceUrl, row.sourceUrl, row.matchStatus, row.clipPresent], ['https://youtu.be/abcdefghijk', 'https://youtu.be/abcdefghijk', 'user-link', false]);
    expect(await names(p.join(lib, 'clips')), isEmpty);
    await e.close();
  });
}
