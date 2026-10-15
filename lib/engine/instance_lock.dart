import 'dart:io';

import 'package:path/path.dart' as p;

/// One running copy of the app per computer: an OS file lock on `instance.lock` in the app-data
/// folder. The operating system releases it if the app crashes, so there is nothing stale to
/// clean up. (The library folder has its own heartbeat lock, because that one has to be
/// visible from another computer.)
class InstanceLock {
  InstanceLock(this.appDataDir);
  final String appDataDir;
  RandomAccessFile? _file;

  String get path => p.join(appDataDir, 'instance.lock');

  /// True when this process now holds the lock; false when another copy is running.
  Future<bool> tryAcquire() async {
    if (_file != null) return true;
    await Directory(appDataDir).create(recursive: true);
    final f = await File(path).open(mode: FileMode.append);
    try {
      await f.lock(FileLock.exclusive);
    } on FileSystemException {
      await f.close();
      return false;
    }
    _file = f;
    return true;
  }

  Future<void> release() async {
    final f = _file;
    _file = null;
    if (f == null) return;
    try {
      await f.unlock();
    } catch (_) {}
    await f.close();
  }
}
