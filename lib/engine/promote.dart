/// Full tracks for starred items. Port of promote.ts / promote.py: download the whole track,
/// keep the original, transcode to the profile's format into `full/<id>/`, write only this
/// module's own fields under the lock afterwards. Reclaim deletes full tracks for unstarred
/// entries only. Starring is the only trigger (hard requirement 8).
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'health.dart';
import 'library.dart';
import 'media.dart';
import 'store.dart';

class PromoteDeps {
  PromoteDeps({required this.download, required this.transcode, this.log});
  final Future<String?> Function(String url, String workdir) download; // path of the downloaded file
  final Future<({bool ok, String? error})> Function(String src, String dest, String format) transcode;
  final void Function(String line)? log;
}

Future<({String status, String? path})> promoteOne(Store store, Track track, String format, PromoteDeps deps, {String? workRoot}) async {
  final root = store.root;
  final fmt = fullFormats.containsKey(format) ? format : 'wav16';
  final ext = fullFormats[fmt]!.ext;
  final destDir = p.join(root, 'full', track.id);
  final dest = p.join(destDir, '${track.id}.$ext');
  final existing = File(dest);
  if (await existing.exists() && await existing.length() > 0) return (status: 'already', path: dest);

  final url = safeMediaUrl(track.userSourceUrl ?? track.sourceUrl);
  if (url == null) return (status: 'no-source', path: null);

  await Directory(destDir).create(recursive: true);
  final workdir = Directory(p.join(workRoot ?? p.join(root, '.work-full'), track.id));
  if (await workdir.exists()) await workdir.delete(recursive: true);
  await workdir.create(recursive: true);
  try {
    final src = await deps.download(url, workdir.path);
    if (src == null) return (status: 'download-failed', path: null);
    // Keep the original: re-transcoding is free, re-downloading may not be possible in six weeks.
    await File(src).copy(p.join(destDir, '${track.id}.source${p.extension(src)}'));
    final r = await deps.transcode(src, dest, fmt);
    if (!r.ok) {
      deps.log?.call('  ! transcode failed: ${r.error ?? ''}');
      return (status: 'transcode-failed', path: null);
    }
    return (status: 'ok', path: dest);
  } finally {
    if (await workdir.exists()) await workdir.delete(recursive: true);
  }
}

class PromoteRunResult {
  PromoteRunResult({required this.done, required this.failed, required this.remaining, required this.totalBytes, required this.count});
  final List<String> done;
  final List<({String label, String status})> failed;
  final List<String> remaining;
  final int totalBytes, count;
}

/// Work a list of ids (normally the promote queue). Downloads run with no lock held.
Future<PromoteRunResult> promoteMany(Store store, List<String> ids, String format, PromoteDeps deps, {void Function(String label, int i, int n)? onProgress, bool Function()? shouldStop}) async {
  final library = Library(await store.readOr('library.json', Library.empty().json));
  final results = <String, ({String status, String? path})>{};
  final done = <String>[];
  final failed = <({String label, String status})>[];
  final wanted = ids.toSet().toList();
  for (var i = 0; i < wanted.length; i++) {
    if (shouldStop?.call() == true) break;
    final tid = wanted[i];
    final track = library.find(tid);
    if (track == null) {
      failed.add((label: tid, status: 'unknown'));
      results[tid] = (status: 'unknown', path: null);
      continue;
    }
    onProgress?.call(track.label, i, wanted.length);
    final r = await promoteOne(store, track, format, deps);
    results[tid] = r;
    if (r.status == 'ok' || r.status == 'already') {
      done.add(track.label);
    } else {
      failed.add((label: track.label, status: r.status));
    }
  }

  // Short critical section: re-read, write only our own fields, re-read the queue.
  var totalBytes = 0, count = 0;
  var remaining = <String>[];
  await store.withLock(() async {
    final lib = Library(await store.readOr('library.json', Library.empty().json));
    for (final e in results.entries) {
      final track = lib.find(e.key);
      if (track == null) continue;
      final r = e.value;
      if ((r.status == 'ok' || r.status == 'already') && r.path != null) {
        track.set('full', p.relative(r.path!, from: store.root).replaceAll('\\', '/'));
        track.set('full_format', fullFormats.containsKey(format) ? format : 'wav16');
        track.set('full_bytes', await File(r.path!).length());
        track.set('promoted_at', nowIso());
        track.remove('full_error');
      } else {
        track.set('full_error', r.status);
      }
    }
    final queue = await store.readOr('promote_queue.json', <String, dynamic>{'ids': <String>[]});
    remaining = ((queue['ids'] as List?) ?? const []).map((e) => e.toString()).where((i) => !results.containsKey(i)).toList();
    await store.writeUnlocked('promote_queue.json', <String, dynamic>{'ids': remaining});
    lib.updated = nowIso();
    await store.writeUnlocked('library.json', lib.json);
    for (final t in lib.tracks) {
      totalBytes += t.fullBytes ?? 0;
      if (t.full != null) count++;
    }
  });

  if (failed.isNotEmpty) {
    final detail = failed.map((f) => '${f.label}: ${f.status}').join('; ');
    await record(store, 'promote', false, '${failed.length} full track(s) could not be downloaded.', detail.length > 400 ? detail.substring(0, 400) : detail);
  } else {
    await clearKind(store, 'promote');
  }
  return PromoteRunResult(done: done, failed: failed, remaining: remaining, totalBytes: totalBytes, count: count);
}

/// Add a track to the promote queue (called when the user stars). False if it already has a full track or is already queued.
Future<bool> queuePromotion(Store store, String trackId) async {
  final library = Library(await store.readOr('library.json', Library.empty().json));
  final track = library.find(trackId);
  if (track == null || track.full != null) return false;
  var added = false;
  await store.update('promote_queue.json', <String, dynamic>{'ids': <String>[]}, (q) {
    final ids = ((q['ids'] as List?) ?? const []).map((e) => e.toString()).toList();
    if (ids.contains(trackId)) return null;
    added = true;
    return <String, dynamic>{'ids': [...ids, trackId]};
  });
  return added;
}

/// promote.py --reclaim: delete full tracks for anything no longer starred. Never touches a favourite or a clip.
Future<({List<String> removed, int freed})> reclaim(Store store) async {
  final removed = <String>[];
  var freed = 0;
  await store.withLock(() async {
    final library = Library(await store.readOr('library.json', Library.empty().json));
    final favourites = Favourites(await store.readOr('favourites.json', Favourites.empty().json)).ids.toSet();
    for (final track in library.tracks) {
      if (track.id.isEmpty || favourites.contains(track.id) || track.full == null) continue;
      final folder = Directory(p.join(store.root, 'full', track.id));
      if (await folder.exists()) {
        freed += await _folderSize(folder);
        await folder.delete(recursive: true);
      }
      removed.add(track.title ?? track.id);
      for (final k in ['full', 'full_format', 'full_bytes', 'promoted_at']) {
        track.remove(k);
      }
    }
    if (removed.isNotEmpty) {
      library.updated = nowIso();
      await store.writeUnlocked('library.json', library.json);
    }
  });
  return (removed: removed, freed: freed);
}

/// What "Free that space" would reclaim: full tracks for unstarred entries.
Future<({int count, int bytes})> reclaimable(Store store) async {
  final library = Library(await store.readOr('library.json', Library.empty().json));
  final favourites = Favourites(await store.readOr('favourites.json', Favourites.empty().json)).ids.toSet();
  var count = 0, bytes = 0;
  for (final t in library.tracks) {
    if (t.full != null && !favourites.contains(t.id)) {
      count++;
      bytes += t.fullBytes ?? 0;
    }
  }
  return (count: count, bytes: bytes);
}

Future<int> _folderSize(Directory dir) async {
  var total = 0;
  await for (final e in dir.list(recursive: true)) {
    if (e is File) total += await e.length();
  }
  return total;
}
