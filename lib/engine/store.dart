/// Safe JSON storage for the library folder. Port of the rules in libstore.py, adjusted where the
/// build brief says so:
///
///  - every write goes to a temporary file in the same folder, is flushed to disk, then renamed
///    over the target (atomic on both macOS and Windows);
///  - before the rename, the previous good copy becomes `<name>.bak`;
///  - a lock around every write so two operations never write at once (directory-based lock,
///    because Windows has no flock);
///  - a corrupt file is first copied aside as `<name>.corrupt-<timestamp>` (never deleted), then
///    restored from .bak and reported as a health event. With no usable backup nothing is
///    changed and the caller gets an error. (The Python claims to leave the damaged file in place
///    but actually overwrites it; this version keeps the copy.)
///  - replacing a file on Windows can fail while antivirus has it open: rename is retried for a
///    few seconds before giving up.
///
/// The write lock is the directory `<root>/.write.lock` holding a `heartbeat` file. Dart's
/// `Directory.create()` succeeds on an existing directory, so the atomic step is the exclusive
/// creation of the heartbeat file (O_EXCL); the heartbeat's modification time is refreshed while
/// the lock is held and a heartbeat older than `lockStale` means the holder is gone, so the lock
/// may be removed. On top of that an in-process mutex (per root) serialises `write` and `update`
/// calls from one process, so concurrent updates never spend their retries racing each other.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'library.dart';

/// 'info' | 'warning' | 'error'
typedef HealthLevel = String;

class HealthEvent {
  HealthEvent({required this.level, required this.message, this.file, required this.at});

  final HealthLevel level;

  /// Short, user-facing, one line. Never mentions Python, Claude or a server.
  final String message;

  /// Which state file this is about, e.g. "library.json".
  final String? file;
  final String at;

  @override
  String toString() => 'HealthEvent($level, $message, file: $file, at: $at)';
}

typedef HealthListener = void Function(HealthEvent event);

class StoreError implements Exception {
  StoreError(this.message, this.code, [this.file]);

  final String message;

  /// 'corrupt-no-backup' | 'locked' | 'io' | 'missing'
  final String code;
  final String? file;

  @override
  String toString() => 'StoreError($code): $message';
}

class ReadResult<T> {
  ReadResult({required this.data, required this.recovered});

  /// `null` when the file does not exist.
  final T? data;

  /// True when the file was restored from .bak during this read.
  final bool recovered;
}

/// JavaScript's `Date.toISOString()`: UTC, millisecond precision, `Z` suffix.
String jsIso(DateTime d) {
  final u = d.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}'
      'T${two(u.hour)}:${two(u.minute)}:${two(u.second)}.${u.millisecond.toString().padLeft(3, '0')}Z';
}

/// 2026-10-10T17-05-33 (colons are not allowed in Windows file names)
String timestampForFilename(DateTime d) => jsIso(d).replaceFirst(RegExp(r'\.\d{3}Z$'), '').replaceAll(':', '-');

/// Windows: ERROR_ACCESS_DENIED, ERROR_SHARING_VIOLATION, ERROR_LOCK_VIOLATION, ERROR_DIR_NOT_EMPTY.
/// POSIX: EPERM, EACCES, EBUSY, ENOTEMPTY (Linux 39, macOS 66).
const Set<int> _retryableRenameWindows = {5, 32, 33, 145};
const Set<int> _retryableRenamePosix = {1, 13, 16, 39, 66};

bool _retryableRename(FileSystemException e) {
  final code = e.osError?.errorCode;
  if (code == null) return false;
  return (Platform.isWindows ? _retryableRenameWindows : _retryableRenamePosix).contains(code);
}

final Random _random = Random.secure();

String _hex(int bytes) => List.generate(bytes, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

class Store {
  Store(
    this.root, {
    this.indent = 2,
    this.renameRetry = const Duration(seconds: 3),
    this.lockStale = const Duration(seconds: 15),
    this.lockRetries = 40,
    HealthListener? onHealth,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    if (onHealth != null) _listeners.add(onHealth);
  }

  final String root;

  /// JSON indentation. The existing library files are written by Python with indent=2.
  final int indent;

  /// How long to keep retrying a rename that fails with a Windows sharing violation.
  final Duration renameRetry;

  /// How old a lock may be before it is considered abandoned.
  final Duration lockStale;
  final int lockRetries;
  final List<HealthListener> _listeners = [];

  /// Injectable clock for tests (health events and the corrupt-copy name, not the lock).
  final DateTime Function() _now;

  /// One in-process queue per root so `write`/`update` from one process never contend on disk.
  static final Map<String, Future<void>> _queues = {};

  void Function() onHealth(HealthListener listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void _emit(HealthLevel level, String message, [String? file]) {
    final event = HealthEvent(level: level, message: message, file: file, at: jsIso(_now()));
    for (final l in List.of(_listeners)) {
      l(event);
    }
  }

  String path(String name) {
    if (name.isEmpty || name == '.' || name == '..' || p.basename(name) != name) {
      throw StoreError('Not a plain file name: $name', 'io', name);
    }
    return p.join(root, name);
  }

  /// Serialise the way the Python did: 2-space indent, non-ASCII kept as is, trailing newline.
  String serialize(Object? data) =>
      indent == 2 ? encodeJson(data) : '${JsonEncoder.withIndent(' ' * indent).convert(data)}\n';

  /// `null` when the text is not JSON or not a JSON object (a state file is always an object, so
  /// anything else counts as damage).
  static Json? _parseObject(String raw) {
    try {
      final v = jsonDecode(raw);
      return v is Map ? v.cast<String, dynamic>() : null;
    } on FormatException {
      return null;
    }
  }

  /// Read and parse a JSON state file. Returns `null` data when the file does not exist.
  /// On corruption: copy aside, restore from .bak, report. Without a usable .bak: throw and
  /// change nothing (except the copy aside, which is additive).
  Future<ReadResult<Json?>> read(String name) async {
    final target = path(name);
    String raw;
    try {
      raw = await File(target).readAsString();
    } on PathNotFoundException {
      return ReadResult(data: null, recovered: false);
    } on FileSystemException catch (err) {
      throw StoreError('Could not read $name: ${err.message}', 'io', name);
    }

    final parsed = _parseObject(raw);
    if (parsed != null) return ReadResult(data: parsed, recovered: false);

    final corruptCopy = '$target.corrupt-${timestampForFilename(_now())}';
    await File(target).copy(corruptCopy);

    final backup = '$target.bak';
    Json? restored;
    try {
      restored = _parseObject(await File(backup).readAsString());
    } on FileSystemException {
      restored = null;
    }
    if (restored == null) {
      _emit(
        'error',
        '$name is damaged and there is no usable backup. A copy was saved as ${p.basename(corruptCopy)}. Nothing has been changed.',
        name,
      );
      throw StoreError('$name is corrupt and ${p.basename(backup)} is unusable', 'corrupt-no-backup', name);
    }

    // Restore the backup over the damaged file (the damaged copy is kept alongside).
    await _writeAtomic(target, serialize(restored), keepBackup: false);
    _emit(
      'warning',
      '$name was damaged and has been restored from its backup. The damaged copy was kept as ${p.basename(corruptCopy)}.',
      name,
    );
    return ReadResult(data: restored, recovered: true);
  }

  /// Read a file that must exist and parse, applying a default when it does not exist.
  Future<Json> readOr(String name, Json fallback) async {
    final r = await read(name);
    return r.data ?? fallback;
  }

  /// Write a JSON state file safely, under the folder lock.
  Future<void> write(String name, Object? data) => _serial(() => withLock(() => writeUnlocked(name, data)));

  /// Write without taking the lock. Only call inside `withLock`.
  Future<void> writeUnlocked(String name, Object? data) => _writeAtomic(path(name), serialize(data), keepBackup: true);

  /// Read-modify-write under one lock. `fn` receives the current value (or `fallback`) and returns
  /// the new value to store. Returning `null` leaves the file untouched.
  Future<Json> update(String name, Json fallback, FutureOr<Json?> Function(Json current) fn) => _serial(
        () => withLock(() async {
          final current = await readOr(name, fallback);
          final next = await fn(current);
          if (next == null) return current;
          await writeUnlocked(name, next);
          return next;
        }),
      );

  /// Queue `fn` behind every other `write`/`update` on this root from this process.
  Future<T> _serial<T>(Future<T> Function() fn) {
    final previous = _queues[root] ?? Future<void>.value();
    final done = Completer<void>();
    _queues[root] = done.future;
    return previous.then((_) => fn()).whenComplete(() {
      done.complete();
      if (identical(_queues[root], done.future)) _queues.remove(root);
    });
  }

  /// Run `fn` while holding the library write lock. Re-entrant calls are not supported. This does
  /// not queue behind the in-process mutex, so a `write` while another caller holds `withLock`
  /// retries on disk and then reports `locked`, as in the TypeScript.
  Future<T> withLock<T>(Future<T> Function() fn) async {
    await Directory(root).create(recursive: true);
    final lock = await _acquireWriteLock();
    try {
      return await fn();
    } finally {
      await lock.release();
    }
  }

  Future<_WriteLock> _acquireWriteLock() async {
    final dir = Directory(p.join(root, '.write.lock'));
    final heartbeat = File(p.join(dir.path, 'heartbeat'));
    final update = Duration(milliseconds: max(1000, lockStale.inMilliseconds ~/ 3));
    var delay = 50;
    String lastReason = '';
    for (var attempt = 0; attempt <= lockRetries; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: delay));
        delay = min(delay * 2, 400);
      }
      try {
        await dir.create();
        await heartbeat.create(exclusive: true);
        await heartbeat.writeAsString(jsIso(DateTime.now()));
        return _WriteLock(dir, heartbeat, update);
      } on PathExistsException {
        lastReason = 'lock file is already being held';
        // Someone holds it. A heartbeat older than `lockStale` was left behind by a crash.
        DateTime? modified;
        try {
          modified = (await heartbeat.stat()).modified;
        } on FileSystemException {
          modified = null;
        }
        if (modified != null && DateTime.now().difference(modified) > lockStale) {
          try {
            await dir.delete(recursive: true);
          } on FileSystemException {
            /* someone else may have removed or taken it; try again */
          }
          delay = 50;
        }
      } on FileSystemException catch (err) {
        lastReason = err.message;
      }
    }
    throw StoreError('Another operation is writing to the library: $lastReason', 'locked');
  }

  Future<void> _writeAtomic(String target, String content, {required bool keepBackup}) async {
    final dir = p.dirname(target);
    await Directory(dir).create(recursive: true);
    final tmp = p.join(dir, '.${p.basename(target)}.tmp-$pid-${_hex(4)}');
    final handle = await File(tmp).open(mode: FileMode.write);
    try {
      await handle.writeString(content);
      await handle.flush();
    } finally {
      await handle.close();
    }

    if (keepBackup && await File(target).exists()) {
      // Only a parseable file becomes the backup; never replace a good .bak with a bad one.
      try {
        if (_parseObject(await File(target).readAsString()) != null) {
          await File(target).copy('$target.bak');
        }
      } on FileSystemException {
        /* leave the existing .bak alone */
      }
    }

    await _renameWithRetry(tmp, target);
  }

  Future<void> _renameWithRetry(String from, String to) async {
    final deadline = DateTime.now().add(renameRetry);
    var delay = 50;
    for (;;) {
      try {
        await File(from).rename(to);
        return;
      } on FileSystemException catch (err) {
        if (!_retryableRename(err) || !DateTime.now().isBefore(deadline)) {
          try {
            await File(from).delete();
          } on FileSystemException {
            /* best effort */
          }
          final code = err.osError?.errorCode;
          throw StoreError(
            'Could not replace ${p.basename(to)}. Another program may have it open. (${code ?? err.message})',
            'io',
            p.basename(to),
          );
        }
        await Future<void>.delayed(Duration(milliseconds: delay));
        delay = min(delay * 2, 500);
      }
    }
  }
}

class _WriteLock {
  _WriteLock(this.dir, this.heartbeat, Duration update) {
    _timer = Timer.periodic(update, (_) => _beat());
  }

  final Directory dir;
  final File heartbeat;
  late final Timer _timer;

  Future<void> _beat() async {
    try {
      await heartbeat.writeAsString(jsIso(DateTime.now()));
    } on FileSystemException {
      /* lost the lock directory; nothing useful to do here */
    }
  }

  Future<void> release() async {
    _timer.cancel();
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      /* already gone */
    }
  }
}
