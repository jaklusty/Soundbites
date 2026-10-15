import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundbites/engine/instance_lock.dart';

void main() {
  test('a second process cannot take the instance lock until the first releases it', () async {
    final dir = await Directory.systemTemp.createTemp('sb-instance-');
    final a = InstanceLock(dir.path);
    expect(await a.tryAcquire(), isTrue);
    expect(await a.tryAcquire(), isTrue); // re-entrant for the same holder

    // Dart file locks are per process, so the second attempt comes from a child process
    // (the `dart` on PATH; `flutter test` runs inside flutter_tester, which cannot run scripts).
    final script = File('${dir.path}/other.dart');
    await script.writeAsString(
      'import "dart:io";\nvoid main() async { final f = await File(r"${a.path}").open(mode: FileMode.append); try { await f.lock(FileLock.exclusive); print("got"); } on FileSystemException { print("held"); } }\n',
    );
    Future<String> other() async {
      final r = await Process.run('dart', [script.path]);
      return (r.stdout as String).trim() + (r.stderr as String).trim();
    }

    expect(await other(), contains('held'));
    await a.release();
    expect(await other(), contains('got'));
    await dir.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
