import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:soundbites/engine/library_lock.dart';

void main() {
  late Directory root;
  Future<List<String>> names() async => root.list().map((e) => p.basename(e.path)).toList();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sb-lock-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  group('LibraryLock', () {
    test('acquires, writes an owner record, and releases cleanly', () async {
      final lock = LibraryLock(root.path, heartbeat: const Duration(seconds: 100));
      final r = await lock.acquire();
      expect(r.status, AcquireStatus.acquired);
      expect(r.owner, isNull);
      final owner = jsonDecode(await File(p.join(root.path, lockDirName, 'owner.json')).readAsString());
      expect(owner['pid'], pid);
      expect(owner['app'], 'Soundbites');
      await lock.release();
      expect(await names(), isNot(contains(lockDirName)));
    });

    test('a second holder sees "held" with the owner while the heartbeat is fresh', () async {
      final a = LibraryLock(root.path, heartbeat: const Duration(seconds: 100));
      await a.acquire();
      final b = LibraryLock(root.path, heartbeat: const Duration(seconds: 100));
      final r = await b.acquire();
      expect(r.status, AcquireStatus.held);
      expect(r.owner?.pid, pid);
      await a.release();
    });

    test('a lock with an old heartbeat is reported stale and can be taken over, never silently removed', () async {
      var t = DateTime.parse('2026-10-10T10:00:00Z');
      DateTime clock() => t;
      final crashed = LibraryLock(root.path,
          heartbeat: const Duration(seconds: 100), staleAfter: const Duration(seconds: 60), now: clock);
      await crashed.acquire();
      // simulate the crash: process gone, heartbeat stops; time moves on
      t = t.add(const Duration(minutes: 5));
      final fresh = LibraryLock(root.path,
          heartbeat: const Duration(seconds: 100), staleAfter: const Duration(seconds: 60), now: clock);
      final r = await fresh.acquire();
      expect(r.status, AcquireStatus.stale);
      expect(r.owner?.app, 'Soundbites');
      // still there: acquire() must not remove it
      expect(await names(), contains(lockDirName));
      final taken = await fresh.takeOver();
      expect(taken.status, AcquireStatus.acquired);
      expect(fresh.isHeld, isTrue);
      await fresh.release();
    });

    test('a lock directory with no readable owner file counts as stale', () async {
      await Directory(p.join(root.path, lockDirName)).create();
      final lock = LibraryLock(root.path);
      final r = await lock.acquire();
      expect(r.status, AcquireStatus.stale);
      expect(r.owner, isNull);
    });

    test('beat() refreshes the heartbeat and keeps the start time', () async {
      var t = DateTime.parse('2026-10-10T10:00:00Z');
      final lock = LibraryLock(root.path, heartbeat: const Duration(seconds: 100), now: () => t);
      await lock.acquire();
      t = t.add(const Duration(seconds: 30));
      await lock.beat();
      final owner = (await lock.readOwner())!;
      expect(owner.started, '2026-10-10T10:00:00.000Z');
      expect(owner.heartbeat, '2026-10-10T10:00:30.000Z');
      await lock.release();
    });
  });
}
