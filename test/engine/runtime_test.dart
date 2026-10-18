// Phase 3 checks with a local-folder feed of three runs, keep_runs 2, and a fake yt-dlp.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:soundbites/engine/engine.dart';
import 'package:soundbites/engine/library.dart';
import 'package:soundbites/engine/library_open.dart';
import 'package:soundbites/engine/media.dart';
import 'package:soundbites/engine/runtime.dart';
import 'package:soundbites/engine/state.dart';
import 'package:soundbites/engine/store.dart';
import 'package:soundbites/engine/tools.dart';
import 'package:soundbites/engine/ytdlp.dart';

class Fake {
  final searches = <String>[];
  final downloads = <String>[];
  ResolvedUpload? Function(String q, List<String> rejected)? resolveImpl;
  void Function()? onDownload;
}

ResolvedUpload defaultResolve(String q, List<String> rejected) {
  final id = ('v${q.replaceAll(RegExp('[^a-zA-Z0-9]'), '').toLowerCase()}00000000000').substring(0, 11);
  if (rejected.contains(id)) {
    final alt = 'alt${id.substring(3)}';
    return ResolvedUpload(videoId: alt, url: 'https://www.youtube.com/watch?v=$alt', title: '$q (alt upload)', channel: 'Someone', duration: 100);
  }
  return ResolvedUpload(videoId: id, url: 'https://www.youtube.com/watch?v=$id', title: '$q (Official Audio)', channel: 'Label', duration: 180);
}

YtDlpImpl fakeYtdlp(Fake f) => YtDlpImpl(
      resolveSearch: (_, q, rejected) async {
        f.searches.add(q);
        return (f.resolveImpl ?? defaultResolve)(q, rejected);
      },
      inspect: (_, _) async => null,
      downloadAudio: (_, url, workdir) async {
        f.downloads.add(url);
        f.onDownload?.call();
        final file = File(p.join(workdir, 'src.webm'));
        await file.writeAsString('audio');
        return DownloadedSource(path: file.path, info: {'duration': 180, 'id': Uri.parse(url).queryParameters['v'] ?? ''});
      },
      downloadFull: (_, _, workdir) async {
        final file = File(p.join(workdir, 'full.webm'));
        await file.writeAsString('full');
        return DownloadedSource(path: file.path);
      },
    );

void main() {
  late String base, lib, feed;

  setUp(() async {
    base = (await Directory.systemTemp.createTemp('sb-rt-')).path;
    lib = p.join(base, 'lib');
    feed = p.join(base, 'feed');
    await Directory(lib).create();
    await Directory(p.join(feed, 'runs')).create(recursive: true);
    await createLibrary(lib);
    await Store(lib).update('profile.json', {}, (prof) => {...prof, 'retention': {'keep_runs': 2}});
    const runs = ['2026-09-01', '2026-09-20', '2026-10-05'];
    await File(p.join(feed, 'index.json')).writeAsString(jsonEncode({'version': 1, 'runs': [for (final r in runs) {'run': r, 'file': 'runs/$r.json', 'count': 2}]}));
    for (final r in runs) {
      await File(p.join(feed, 'runs', '$r.json')).writeAsString(jsonEncode({'run': r, 'candidates': [
        {'title': 'Song $r', 'artist': 'Artist A', 'search': 'Artist A Song $r', 'direction': 'rising', 'mood': 'a, b', 'suits': ['x', 'y']},
        {'title': 'Other $r', 'artist': 'Artist B', 'search': 'Artist B Other $r', 'direction': 'peaking'},
        {'title': 'Shared', 'artist': 'Artist C', 'search': 'Artist C Shared'},
      ]}));
    }
  });
  tearDown(() => Directory(base).delete(recursive: true));

  Runtime makeRuntime(Engine e, Fake f) => Runtime(e, RuntimeOptions(
        toolsDir: p.join(base, 'tools'),
        ffmpegPath: 'ffmpeg-fake',
        platform: Platform.darwin,
        arch: Arch.arm64,
        skipTools: true,
        ytdlp: fakeYtdlp(f),
        now: () => DateTime.utc(2026, 10, 10, 12),
        clipImpl: (src, dest, _) async {
          await File(src).copy(dest);
          return MediaResult.ok();
        },
        measureRmsImpl: (_) async => null,
      ));

  Future<void> waitIdle(Runtime rt, Engine e, [int ms = 10000]) async {
    final t0 = DateTime.now();
    while (DateTime.now().difference(t0).inMilliseconds < ms) {
      final s = await e.snapshot();
      final busy = rt.working || rt.promoting || s.feed.queueLength > 0 || s.promoting != null;
      if (!busy) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError('runtime did not go idle');
  }

  Future<Engine> openEngine() async {
    final e = Engine(appDataDir: p.join(base, 'app'), version: '0.2.0');
    await e.settings.load();
    await e.settings.update((s) => s.copyWith(feedBase: feed, updateCheckedAt: '2026-10-10T11:00:00Z'));
    await e.open(lib);
    return e;
  }

  Track byTitle(AppState s, String title) => s.tracks.firstWhere((t) => t.title == title);

  test('oldest run is metadata only, the newest two get clips, oldest first; done runs are never re-ingested', () async {
    final e = await openEngine();
    final f = Fake();
    final rt = makeRuntime(e, f);
    await rt.checkFeed();
    await waitIdle(rt, e);

    var s = await e.snapshot();
    expect(s.tracks.length, 7); // 2 unique per run + Shared once
    final old = s.tracks.where((t) => t.title!.endsWith('2026-09-01'));
    expect(old.every((t) => !t.clipPresent && t.match == null), isTrue);
    final newer = s.tracks.where((t) => RegExp('2026-09-20|2026-10-05').hasMatch(t.title!));
    expect(newer.every((t) => t.clipPresent && (t.match!['title'] as String).contains('Official')), isTrue);
    expect(f.searches.indexWhere((q) => q.contains('2026-09-20')), lessThan(f.searches.indexWhere((q) => q.contains('2026-10-05'))));
    expect(f.searches.any((q) => q.contains('2026-09-01')), isFalse);
    expect(byTitle(s, 'Shared').runs, ['2026-09-01', '2026-09-20', '2026-10-05']);
    final state = (await Store(lib).read('feed_state.json')).data!;
    expect((state['runs'] as Map).values.map((r) => (r as Map)['state']).toList(), ['done', 'done', 'done']);
    expect(s.lastRun, '2026-10-05');

    final before = f.downloads.length;
    await rt.checkFeed();
    await waitIdle(rt, e);
    expect(f.downloads.length, before);
    s = await e.snapshot();
    expect(s.feed.lastResult, 'up to date');
    rt.stop();
    await e.close();
  });

  test('quitting mid-run and reopening resumes without duplicates', () async {
    final e = await openEngine();
    final f = Fake();
    var rt = makeRuntime(e, f);
    f.onDownload = () {
      if (f.downloads.length == 2) rt.cancel(); // "quit" after two clips
    };
    await rt.checkFeed();
    await waitIdle(rt, e);
    var s = await e.snapshot();
    final state1 = (await Store(lib).read('feed_state.json')).data!;
    expect((state1['runs'] as Map).values.any((r) => const ['in-progress', 'queued'].contains((r as Map)['state'])), isTrue);
    expect(s.tracks.where((t) => t.clipPresent).length, 2);
    rt.stop();
    await e.close();

    final e2 = Engine(appDataDir: p.join(base, 'app'), version: '0.2.0');
    await e2.start();
    expect((await e2.snapshot()).library.status, LibraryStatus.open);
    f.onDownload = null;
    rt = makeRuntime(e2, f);
    await rt.checkFeed();
    await waitIdle(rt, e2);
    s = await e2.snapshot();
    expect(s.tracks.length, 7);
    expect(s.tracks.map((t) => t.id).toSet().length, 7);
    expect(s.tracks.where((t) => t.clipPresent).length, 5);
    expect(f.downloads.length, 5);
    for (final t in s.tracks) {
      expect(t.runs.length, t.runs.toSet().length);
    }
    rt.stop();
    await e2.close();
  });

  test('no confident match lands as such; wrong track then a pasted link survives the next run', () async {
    final e = await openEngine();
    final f = Fake();
    f.resolveImpl = (q, rejected) {
      if (q.contains('Artist B Other 2026-10-05')) {
        return const ResolvedUpload(videoId: 'unrelated00', url: 'https://www.youtube.com/watch?v=unrelated00', title: 'Top 50 chart countdown', channel: 'ChartsDaily', duration: 3000);
      }
      return defaultResolve(q, rejected);
    };
    final rt = makeRuntime(e, f);
    await rt.checkFeed();
    await waitIdle(rt, e);
    var s = await e.snapshot();
    final noMatch = byTitle(s, 'Other 2026-10-05');
    expect(noMatch.matchStatus, 'no-confident-match');
    expect(noMatch.clipPresent, isFalse);
    expect(s.issues.any((i) => i.message.contains('no confident match')), isTrue);

    final shared = byTitle(s, 'Shared');
    final firstId = shared.match!['video_id'] as String;
    await e.rejectMatch(shared.id, false);
    await rt.retryTrack(shared.id);
    await waitIdle(rt, e);
    s = await e.snapshot();
    final shared2 = byTitle(s, 'Shared');
    expect(shared2.rejectedVideoIds, [firstId]);
    expect(shared2.match!['video_id'], 'alt${firstId.substring(3)}');
    expect(shared2.clipPresent, isTrue);

    await e.setTrackLink(shared2.id, 'https://youtu.be/userlink001');
    await rt.retryTrack(shared2.id);
    await waitIdle(rt, e);
    await File(p.join(feed, 'runs', '2026-10-08.json')).writeAsString(jsonEncode({'run': '2026-10-08', 'candidates': [
      {'title': 'Shared', 'artist': 'Artist C', 'search': 'Artist C Shared', 'source_url': 'https://www.youtube.com/watch?v=feedlink001'},
    ]}));
    await File(p.join(feed, 'index.json')).writeAsString(jsonEncode({'version': 1, 'runs': [for (final r in ['2026-09-01', '2026-09-20', '2026-10-05', '2026-10-08']) {'run': r, 'file': 'runs/$r.json'}]}));
    await rt.checkFeed();
    await waitIdle(rt, e);
    s = await e.snapshot();
    final shared3 = byTitle(s, 'Shared');
    expect(shared3.userSourceUrl, 'https://youtu.be/userlink001');
    expect(shared3.sourceUrl, 'https://youtu.be/userlink001');
    expect(shared3.runs, contains('2026-10-08'));
    expect(f.downloads.where((u) => u.contains('userlink001')).length, greaterThanOrEqualTo(1));
    expect(f.downloads.any((u) => u.contains('feedlink001')), isFalse);
    rt.stop();
    await e.close();
  });

  test('retry-all queues recent tracks without a clip, not the metadata-only old runs', () async {
    final e = await openEngine();
    final f = Fake();
    final rt = makeRuntime(e, f);
    await rt.checkFeed();
    await waitIdle(rt, e);
    // Pretend the newest two runs produced nothing: remove the clips and mark the reason.
    for (final f in Directory(p.join(lib, 'clips')).listSync()) {
      f.deleteSync();
    }
    await Store(lib).update('library.json', {}, (json) {
      for (final t in (json['tracks'] as List).cast<Map<String, dynamic>>()) {
        t['clip_present'] = false;
        t['clip'] = null;
        t['audio_error'] = 'search failed';
      }
      return json;
    });
    final before = f.downloads.length;
    final queued = await rt.retryAllNoAudio();
    await waitIdle(rt, e);
    expect(queued, 5); // keep_runs 2: the five tracks of the newest two runs, not the two from 2026-09-01
    expect(f.downloads.length - before, 5);
    final s = await e.snapshot();
    expect(s.tracks.where((t) => t.clipPresent).length, 5);
    // The two metadata-only tracks from the oldest run keep their note; the retried five lose it.
    expect(s.tracks.where((t) => t.json['audio_error'] != null).map((t) => t.runs.single).toList(), ['2026-09-01', '2026-09-01']);
    rt.stop();
    await e.close();
  });

  test('the first start of a new app version retries recent tracks without a clip', () async {
    final e = await openEngine();
    final f = Fake();
    var rt = makeRuntime(e, f);
    await rt.checkFeed();
    await waitIdle(rt, e);
    for (final file in Directory(p.join(lib, 'clips')).listSync()) {
      file.deleteSync();
    }
    await Store(lib).update('library.json', {}, (json) {
      for (final t in (json['tracks'] as List).cast<Map<String, dynamic>>()) {
        t['clip_present'] = false;
        t['clip'] = null;
      }
      return json;
    });
    expect((await e.snapshot()).retryableCount, 5);
    rt.stop();
    // No version on record (as after 0.2.0) still counts as a change.
    expect(e.settings.current.lastAppVersion, isNull);
    final before = f.downloads.length;
    rt = makeRuntime(e, f);
    await rt.start();
    await waitIdle(rt, e);
    expect(f.downloads.length - before, 5);
    expect(e.settings.current.lastAppVersion, '0.2.0');
    expect((await e.snapshot()).retryableCount, 0);
    rt.stop();
    await e.close();
  });

  test('a starred track gets its full track pulled in the background', () async {
    final e = await openEngine();
    final f = Fake();
    final rt = makeRuntime(e, f);
    await rt.checkFeed();
    await waitIdle(rt, e);
    final s = await e.snapshot();
    final t = s.tracks.firstWhere((x) => x.clipPresent);
    // The fake download writes full.webm; transcoding fails without ffmpeg, so this checks the
    // queue plumbing and the error path rather than audio output.
    await e.star(t.id, true);
    await waitIdle(rt, e);
    final after = await e.snapshot();
    expect(after.favourites, {t.id});
    expect(after.promoteQueue, isEmpty);
    final row = after.tracks.firstWhere((x) => x.id == t.id);
    expect(row.full ?? row.json['full_error'], isNotNull);
    rt.stop();
    await e.close();
  });
}
