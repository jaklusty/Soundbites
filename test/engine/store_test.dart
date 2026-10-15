import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:soundbites/engine/health.dart' as health;
import 'package:soundbites/engine/store.dart';

void main() {
  late Directory root;
  late List<HealthEvent> events;
  late Store store;

  Future<String> readText(String name) => File(p.join(root.path, name)).readAsString();
  Future<List<String>> names() async => root.list().map((e) => p.basename(e.path)).toList();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sb-store-');
    events = [];
    store = Store(root.path, onHealth: events.add, now: () => DateTime.utc(2026, 10, 10, 17, 5, 33));
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  group('Store', () {
    test('returns null for a missing file', () async {
      final r = await store.read('library.json');
      expect(r.data, isNull);
      expect(r.recovered, isFalse);
    });

    test('writes atomically with a trailing newline and 2-space indent, no temp files left', () async {
      await store.write('library.json', {'version': 1, 'tracks': []});
      expect(await readText('library.json'), '{\n  "version": 1,\n  "tracks": []\n}\n');
      expect((await names()).where((f) => f.contains('.tmp-')), isEmpty);
    });

    test('keeps non-ASCII characters as written', () async {
      await store.write('t.json', {'title': 'Café — 東京 🎵'});
      expect(await readText('t.json'), contains('Café — 東京 🎵'));
    });

    test('keeps a .bak of the previous good copy on every write', () async {
      await store.write('library.json', {'v': 1});
      expect(await names(), isNot(contains('library.json.bak')));
      await store.write('library.json', {'v': 2});
      expect(jsonDecode(await readText('library.json.bak')), {'v': 1});
      await store.write('library.json', {'v': 3});
      expect(jsonDecode(await readText('library.json.bak')), {'v': 2});
    });

    test('restores a corrupt file from .bak, keeps a .corrupt copy, and reports a warning', () async {
      await store.write('favourites.json', {
        'ids': ['a']
      });
      await store.write('favourites.json', {
        'ids': ['a', 'b']
      });
      await File(p.join(root.path, 'favourites.json')).writeAsString('{"ids": ["a", "b"');
      final r = await store.read('favourites.json');
      expect(r.recovered, isTrue);
      expect(r.data, {
        'ids': ['a']
      });
      expect(await names(), contains('favourites.json.corrupt-2026-10-10T17-05-33'));
      expect(await readText('favourites.json.corrupt-2026-10-10T17-05-33'), '{"ids": ["a", "b"');
      expect(jsonDecode(await readText('favourites.json')), {
        'ids': ['a']
      });
      expect(events, hasLength(1));
      expect(events[0].level, 'warning');
      expect(events[0].message, matches(RegExp(r'restored from its backup')));
      expect(events[0].message, isNot(matches(RegExp(r'python|server|claude', caseSensitive: false))));
    });

    test('with no usable backup: copies aside, changes nothing, throws corrupt-no-backup', () async {
      await File(p.join(root.path, 'library.json')).writeAsString('not json');
      await expectLater(
        store.read('library.json'),
        throwsA(isA<StoreError>().having((e) => e.code, 'code', 'corrupt-no-backup')),
      );
      expect(await readText('library.json'), 'not json');
      expect(await names(), contains('library.json.corrupt-2026-10-10T17-05-33'));
      expect(events[0].level, 'error');
    });

    test('a corrupt .bak is not usable either', () async {
      await File(p.join(root.path, 'library.json')).writeAsString('{');
      await File(p.join(root.path, 'library.json.bak')).writeAsString('[');
      await expectLater(
        store.read('library.json'),
        throwsA(isA<StoreError>().having((e) => e.code, 'code', 'corrupt-no-backup')),
      );
      expect(await readText('library.json.bak'), '[');
    });

    test('never overwrites a good .bak with a corrupt current file', () async {
      await store.write('p.json', {'good': true});
      await store.write('p.json', {'good': 2});
      await File(p.join(root.path, 'p.json')).writeAsString('garbage');
      // A write while the current file is corrupt must not promote the garbage to .bak
      await store.write('p.json', {'good': 3});
      expect(jsonDecode(await readText('p.json.bak')), {'good': true});
    });

    test('update() does read-modify-write under one lock and can leave the file untouched', () async {
      await store.write('c.json', {'n': 1});
      final r = await store.update('c.json', {'n': 0}, (cur) => {'n': (cur['n'] as int) + 1});
      expect(r, {'n': 2});
      final r2 = await store.update('c.json', {'n': 0}, (_) => null);
      expect(r2, {'n': 2});
    });

    test('serialises concurrent writers; last write wins and no file is ever half-written', () async {
      await Future.wait(List.generate(
        12,
        (i) => store.update('c.json', {'n': 0}, (c) => {'n': (c['n'] as int) + 1 + 0 * i}),
      ));
      expect(jsonDecode(await readText('c.json')), {'n': 12});
    });

    test('rejects names that are not plain file names', () {
      expect(() => store.path('../x.json'), throwsA(isA<StoreError>()));
      expect(() => store.path('sub/x.json'), throwsA(isA<StoreError>()));
    });

    test('reports a locked library instead of waiting forever', () async {
      final slow = Store(root.path, lockRetries: 1, lockStale: const Duration(seconds: 60));
      final hold = Completer<void>();
      final holding = slow.withLock(() => hold.future);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await expectLater(
        slow.write('x.json', {}),
        throwsA(isA<StoreError>().having((e) => e.code, 'code', 'locked')),
      );
      hold.complete();
      await holding;
    });
  });

  group('health', () {
    test('record appends in the Python shape, caps at 40 and sets updated', () async {
      for (var i = 0; i < 45; i++) {
        await health.record(store, 'feed', false, 'Feed check failed', 'attempt $i');
      }
      final data = jsonDecode(await readText('health.json')) as Map<String, dynamic>;
      final events = data['events'] as List;
      expect(events, hasLength(health.maxEvents));
      expect((events.first as Map).keys.toList(), ['at', 'kind', 'ok', 'message', 'detail']);
      expect(events.first['detail'], 'attempt 5');
      expect(events.last['detail'], 'attempt 44');
      expect(data['updated'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+00:00$')));
      expect(events.last['at'], data['updated']);
    });

    test('clearKind drops only that kind and leaves the file alone when nothing matches', () async {
      await health.record(store, 'feed', false, 'a');
      await health.record(store, 'tools', false, 'b');
      await health.clearKind(store, 'feed');
      var events = (jsonDecode(await readText('health.json')) as Map)['events'] as List;
      expect(events.map((e) => e['kind']), ['tools']);
      final before = await File(p.join(root.path, 'health.json')).lastModified();
      await health.clearKind(store, 'nothing');
      expect(await File(p.join(root.path, 'health.json')).lastModified(), before);
      events = (jsonDecode(await readText('health.json')) as Map)['events'] as List;
      expect(events, hasLength(1));
    });

    test('never throws, even when the folder cannot be written', () async {
      final broken = Store(p.join(root.path, 'file-not-dir'));
      await File(p.join(root.path, 'file-not-dir')).writeAsString('x');
      await health.record(broken, 'feed', false, 'a');
      await health.clearKind(broken, 'feed');
    });
  });
}
