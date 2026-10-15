/// The library-folder lock (hard requirement 9, second half). One app instance per machine is
/// handled by the single-instance lock; this stops a second computer or user account from
/// writing to the same library folder, and detects a lock left behind by a crash so it can be
/// offered for take-over instead of blocking the user.
///
/// Design: a directory `soundbites.lock` inside the library folder containing `owner.json` with
/// who holds it and a heartbeat timestamp that is refreshed every `heartbeat`. A lock whose
/// heartbeat is older than `staleAfter` is reported as stale. The caller decides whether to take
/// it over.
///
/// Dart's `Directory.create()` succeeds on an existing directory, so an existing lock directory
/// is detected first and the atomic claim is the exclusive creation of `owner.json` inside it:
/// two instances that both create the directory at once still end up with exactly one holder.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'store.dart' show jsIso;

class LockOwner {
  LockOwner({
    required this.host,
    required this.user,
    required this.pid,
    required this.app,
    required this.started,
    required this.heartbeat,
  });

  factory LockOwner.fromJson(Map<String, dynamic> json) => LockOwner(
        host: (json['host'] ?? '').toString(),
        user: (json['user'] ?? '').toString(),
        pid: (json['pid'] as num?)?.toInt() ?? 0,
        app: (json['app'] ?? '').toString(),
        started: (json['started'] ?? '').toString(),
        heartbeat: (json['heartbeat'] ?? '').toString(),
      );

  final String host;
  final String user;
  final int pid;
  final String app;
  final String started;
  final String heartbeat;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'host': host,
        'user': user,
        'pid': pid,
        'app': app,
        'started': started,
        'heartbeat': heartbeat,
      };

  @override
  String toString() => 'LockOwner(${jsonEncode(toJson())})';
}

enum AcquireStatus { acquired, held, stale }

/// `acquired` has no owner; `held` always has one; `stale` has one when the owner file is readable.
class AcquireResult {
  const AcquireResult(this.status, [this.owner]);

  final AcquireStatus status;
  final LockOwner? owner;

  @override
  String toString() => 'AcquireResult(${status.name}${owner == null ? '' : ', $owner'})';
}

const String lockDirName = 'soundbites.lock';

class LibraryLock {
  LibraryLock(
    String libraryRoot, {
    this.heartbeat = const Duration(seconds: 15),
    this.staleAfter = const Duration(seconds: 60),
    this.appLabel = 'Soundbites',
    DateTime Function()? now,
  })  : _dir = Directory(p.join(libraryRoot, lockDirName)),
        _ownerFile = File(p.join(libraryRoot, lockDirName, 'owner.json')),
        _now = now ?? DateTime.now;

  final Directory _dir;
  final File _ownerFile;
  final Duration heartbeat;
  final Duration staleAfter;
  final String appLabel;
  final DateTime Function() _now;
  Timer? _timer;
  bool _held = false;

  bool get isHeld => _held;

  LockOwner _ownerRecord(String started) {
    var user = 'unknown';
    try {
      final env = Platform.environment;
      user = env['USER'] ?? env['USERNAME'] ?? 'unknown';
    } catch (_) {
      /* some locked-down accounts throw */
    }
    String host;
    try {
      host = Platform.localHostname;
    } catch (_) {
      host = 'unknown';
    }
    return LockOwner(host: host, user: user, pid: pid, app: appLabel, started: started, heartbeat: jsIso(_now()));
  }

  Future<LockOwner?> readOwner() async {
    try {
      final v = jsonDecode(await _ownerFile.readAsString());
      return v is Map ? LockOwner.fromJson(v.cast<String, dynamic>()) : null;
    } catch (_) {
      return null;
    }
  }

  Future<AcquireResult> _heldOrStale() async {
    final owner = await readOwner();
    if (owner != null && isFresh(owner)) return AcquireResult(AcquireStatus.held, owner);
    // No readable owner file, or a heartbeat older than staleAfter: left behind by a crash.
    return AcquireResult(AcquireStatus.stale, owner);
  }

  /// Try to take the lock. Never removes someone else's lock; reports `stale` instead.
  Future<AcquireResult> acquire() async {
    if (await _dir.exists()) return _heldOrStale();
    try {
      await _dir.create();
      await _ownerFile.create(exclusive: true);
    } on PathExistsException {
      return _heldOrStale();
    }
    await _writeOwner(_ownerRecord(jsIso(_now())));
    _held = true;
    _startHeartbeat();
    return const AcquireResult(AcquireStatus.acquired);
  }

  /// Remove a stale lock and acquire. Only call after the user agreed to take over.
  Future<AcquireResult> takeOver() async {
    await _removeDir();
    return acquire();
  }

  Future<void> release() async {
    _stopHeartbeat();
    if (!_held) return;
    _held = false;
    await _removeDir();
  }

  /// Heartbeat age check. An owner file with an unparseable date counts as stale.
  bool isFresh(LockOwner owner) {
    final t = DateTime.tryParse(owner.heartbeat);
    if (t == null) return false;
    return _now().difference(t) < staleAfter;
  }

  /// Public for tests: write one heartbeat now.
  Future<void> beat() async {
    final current = await readOwner();
    final started = current?.started ?? jsIso(_now());
    await _writeOwner(_ownerRecord(started));
  }

  Future<void> _writeOwner(LockOwner owner) async {
    final tmp = File('${_ownerFile.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(owner.toJson()));
    await tmp.rename(_ownerFile.path);
  }

  Future<void> _removeDir() async {
    try {
      await _dir.delete(recursive: true);
    } on FileSystemException {
      /* already gone */
    }
  }

  void _startHeartbeat() {
    _stopHeartbeat();
    _timer = Timer.periodic(heartbeat, (_) {
      beat().catchError((Object _) {});
    });
  }

  void _stopHeartbeat() {
    _timer?.cancel();
    _timer = null;
  }
}
