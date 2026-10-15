import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:soundbites/engine/hook.dart';
import 'package:soundbites/engine/ids.dart';
import 'package:soundbites/engine/ingest.dart';
import 'package:soundbites/engine/library.dart';
import 'package:soundbites/engine/store.dart';
import 'package:soundbites/engine/ytdlp.dart';

void main() {
  group('candidate normalisation', () {
    test('mood string becomes a list and a suits list becomes one string', () {
      final c = normalizeCandidate({'title': 'T', 'artist': 'A', 'mood': 'dark, moody; slow', 'suits': ['one', 'two']}, CandidateSource.feed) as Candidate;
      expect(c.mood, ['dark', 'moody', 'slow']);
      expect(c.suits, 'one two');
    });
    test('feed candidates lose local-only fields and non-YouTube links', () {
      final c = normalizeCandidate({'title': 'T', 'artist': 'A', 'local': '/x.mp3', 'pin': true, 'profiles': ['moto'], 'hook_start': '0:30', 'source_url': 'https://example.com/a'}, CandidateSource.feed) as Candidate;
      expect(c.local, isNull);
      expect(c.pin, isFalse);
      expect(c.profiles, isNull);
      expect(c.hookStart, isNull);
      expect(c.sourceUrl, isNull);
      final yt = normalizeCandidate({'title': 'T', 'artist': 'A', 'source_url': 'https://youtu.be/abcdefghijk'}, CandidateSource.feed) as Candidate;
      expect(yt.sourceUrl, 'https://youtu.be/abcdefghijk');
    });
    test('pending candidates keep hook_start and local', () {
      final c = normalizeCandidate({'title': 'T', 'artist': 'A', 'local': '/x.mp3', 'hook_start': '0:30', 'pin': 1}, CandidateSource.pending) as Candidate;
      expect(c.local, '/x.mp3');
      expect(c.hookStart, '0:30');
      expect(c.pin, isTrue);
    });
    test('rejects a candidate with no title', () {
      expect(normalizeCandidate({'artist': 'A'}, CandidateSource.feed), isA<Rejected>());
    });
    test('helpers', () {
      expect(parseTs('0:20'), 20);
      expect(parseTs('1:05.9'), 65);
      expect(parseTs(95.7), 95);
      expect(parseTs('x'), 20);
      expect(parseTs(null), 20);
      expect(validRunStamp('2026-02-30'), isFalse);
      expect(validRunStamp('2026-10-10'), isTrue);
      expect(newerStamp('2026-08-29', '2026-10-10'), '2026-10-10');
      expect(newerStamp(null, '2026-10-10'), '2026-10-10');
      expect(newerStamp('2026-10-10', 'junk'), '2026-10-10');
      expect(youtubeUrlOnly('https://music.youtube.com/watch?v=abc'), isNotNull);
      expect(youtubeUrlOnly('https://notyoutube.com/watch?v=abc'), isNull);
      expect(youtubeUrlOnly('-https://youtube.com/x'), isNull);
      expect(youtubeVideoId('https://youtu.be/u5Ee8QrWyhc?t=1'), 'u5Ee8QrWyhc');
      expect(youtubeVideoId('https://www.youtube.com/shorts/u5Ee8QrWyhc'), 'u5Ee8QrWyhc');
      expect(youtubeVideoId('https://www.youtube.com/watch?v=short'), isNull);
    });
  });

  test('match transparency', () {
    expect(confidentMatch(uploadTitle: 'Bicep - Glue (Official Video)', uploadChannel: 'BicepVEVO', title: 'Glue', artist: 'Bicep'), isTrue);
    expect(confidentMatch(uploadTitle: 'Some random vlog', uploadChannel: 'Echo & The Bunnymen', title: 'The Killing Moon', artist: 'Echo & The Bunnymen'), isTrue);
    expect(confidentMatch(uploadTitle: 'Top 10 songs of 2026', uploadChannel: 'ChartsDaily', title: 'Glue', artist: 'Bicep'), isFalse);
  });

  group('merge and dry run', () {
    test('dry run counts new, known and duplicate ids', () {
      final lib = Library.empty();
      lib.add(Track.create(id: slugify('Bicep', 'Glue'), firstSeen: '2026-09-21'));
      final cands = [Candidate(title: 'Glue', artist: 'Bicep'), Candidate(title: 'glue', artist: 'BICEP'), Candidate(title: 'New', artist: 'Someone')];
      final d = dryRun(lib, cands, '2026-10-10', 8);
      expect([d.candidates, d.fresh, d.known, d.keepRuns, d.duplicateIds], [3, 1, 2, 8, 1]);
    });
    test('merge files a new row with defaults and never overwrites a user-set link', () {
      final lib = Library.empty();
      final rec = mergeTrack(lib, Candidate(title: 'Glue', artist: 'Bicep')..uses = 10..sourceUrl = 'https://youtu.be/aaaaaaaaaaa', 'id1', '2026-10-10', null, 0);
      expect(rec.json.keys.take(5).toList(), ['id', 'first_seen', 'runs', 'clip', 'clip_present']);
      expect(rec.runs, ['2026-10-10']);
      expect(rec.mood, isEmpty);
      expect(rec.licence, 'platform');
      expect(rec.usesHistory, {'2026-10-10': 10});
      rec.set('user_source_url', 'https://youtu.be/bbbbbbbbbbb');
      mergeTrack(lib, Candidate(title: 'Glue', artist: 'Bicep')..sourceUrl = 'https://youtu.be/ccccccccccc', 'id1', '2026-10-12', 'clips/id1.mp3', 123, HookResult(at: 20, method: 'default', detail: 'x'));
      expect(rec.sourceUrl, 'https://youtu.be/aaaaaaaaaaa');
      expect(rec.runs, ['2026-10-10', '2026-10-12']);
      expect(rec.clipPresent, isTrue);
      expect(rec.hookAt, 20);
    });
  });

  group('runIngest', () {
    late Directory root;
    late Store store;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('sb-ingest-');
      store = Store(root.path);
      await Directory(p.join(root.path, 'clips')).create();
    });
    tearDown(() => root.delete(recursive: true));

    IngestDeps deps({Future<ResolvedUpload?> Function(String, List<String>)? resolve, Future<DownloadedSource?> Function(String, String)? download, bool Function()? shouldStop, bool downloadAudio = true, void Function(IngestProgress)? onProgress}) => IngestDeps(
          resolve: resolve ?? (search, _) async => ResolvedUpload(videoId: 'vid00000001', url: 'https://www.youtube.com/watch?v=vid00000001', title: '$search (Official)', channel: 'Channel', duration: 200),
          inspect: (_) async => null,
          download: download ??
              (url, workdir) async {
                final f = File(p.join(workdir, 'src.webm'));
                await f.writeAsString('audio');
                return DownloadedSource(path: f.path, info: {'duration': 200});
              },
          clip: (src, dest, at) async {
            await File(dest).writeAsString('clipclipclip');
            return (ok: true, error: null);
          },
          shouldStop: shouldStop,
          downloadAudio: downloadAudio,
          onProgress: onProgress,
        );

    final cands = [
      Candidate(title: 'Glue', artist: 'Bicep')..search = 'Bicep Glue'..direction = 'rising',
      Candidate(title: 'Muscle Drive', artist: 'Wbsound')..search = 'Wbsound Muscle Drive',
      Candidate(title: 'glue', artist: 'bicep'),
    ];

    test('files rows first, fills clips, prunes once, writes last_run.json and no health error', () async {
      final phases = <String>[];
      final r = await runIngest(store, '2026-10-10', cands, deps(onProgress: (pr) => phases.add(pr.phase)));
      expect([r.added, r.updated, r.noAudio, r.rejected, r.clipsKept, r.tracked], [2, 0, 0, 1, 2, 2]);
      final lib = Library(await store.readOr('library.json', {}));
      expect(lib.lastRun, '2026-10-10');
      final glue = lib.tracks.firstWhere((t) => t.title == 'Glue');
      expect(glue.clipPresent, isTrue);
      expect(glue.match!['video_id'], 'vid00000001');
      expect(glue.matchStatus, 'matched');
      expect(glue.sourceUrl, 'https://www.youtube.com/watch?v=vid00000001');
      expect(phases.first, 'filing');
      expect(phases.last, 'done');
      expect((await store.readOr('last_run.json', {}))['run'], '2026-10-10');
      expect(((await store.readOr('health.json', {'events': []}))['events'] as List), isEmpty);
    });

    test('no confident match → row without audio, status recorded, one health line per run', () async {
      final r = await runIngest(store, '2026-10-10', cands.sublist(0, 2), deps(resolve: (_, _) async => const ResolvedUpload(videoId: 'vid00000002', url: 'https://www.youtube.com/watch?v=vid00000002', title: 'Top 10 songs', channel: 'ChartsDaily', duration: 500)));
      expect(r.noAudio, 2);
      expect(r.noMatch, 2);
      final lib = Library(await store.readOr('library.json', {}));
      expect(lib.tracks.every((t) => t.matchStatus == 'no-confident-match' && !t.clipPresent), isTrue);
      final events = (await store.readOr('health.json', {}))['events'] as List;
      expect(events.length, 1);
      expect((events.first as Map)['message'], startsWith('Run 2026-10-10 downloaded nothing: 2 tracks had no audio'));
    });

    test('a stopped run stays unpruned and resumes without duplicates', () async {
      var calls = 0;
      final first = await runIngest(store, '2026-10-10', cands.sublist(0, 2), deps(shouldStop: () => calls++ >= 1));
      expect(first.stopped, isTrue);
      var lib = Library(await store.readOr('library.json', {}));
      expect(lib.tracks.length, 2);
      expect(lib.tracks.where((t) => t.clipPresent).length, 1);
      var downloads = 0;
      final second = await runIngest(store, '2026-10-10', cands.sublist(0, 2), deps(download: (u, w) async {
        downloads++;
        final f = File(p.join(w, 'src.webm'));
        await f.writeAsString('a');
        return DownloadedSource(path: f.path);
      }));
      expect(second.stopped, isFalse);
      expect(downloads, 1);
      lib = Library(await store.readOr('library.json', {}));
      expect(lib.tracks.length, 2);
      expect(lib.tracks.where((t) => t.clipPresent).length, 2);
      expect(lib.tracks.first.runs, ['2026-10-10']);
    });

    test('metadata-only runs file rows and download nothing', () async {
      var downloads = 0;
      final r = await runIngest(store, '2026-09-01', cands.sublist(0, 2), deps(downloadAudio: false, download: (_, _) async {
        downloads++;
        return null;
      }));
      expect(downloads, 0);
      expect(r.noAudio, 0);
      final lib = Library(await store.readOr('library.json', {}));
      expect(lib.tracks.length, 2);
      expect(lib.tracks.every((t) => !t.clipPresent), isTrue);
    });

    test('prune keeps favourites, pinned and recent runs and sweeps only known ids', () async {
      final lib = Library({'version': 1, 'tracks': [
        {'id': 'old', 'first_seen': '2026-01-01', 'runs': ['2026-01-01'], 'clip': 'clips/old.mp3', 'clip_present': true, 'clip_bytes': 3},
        {'id': 'fav', 'first_seen': '2026-01-01', 'runs': ['2026-01-01'], 'clip': 'clips/fav.mp3', 'clip_present': true, 'clip_bytes': 3},
        {'id': 'pin', 'first_seen': '2026-01-01', 'runs': ['2026-01-01'], 'clip': 'clips/pin.mp3', 'clip_present': true, 'pinned': true},
        {'id': 'new', 'first_seen': '2026-10-10', 'runs': ['2026-10-10'], 'clip': 'clips/new.mp3', 'clip_present': true},
      ]});
      for (final n in ['old', 'fav', 'pin', 'new', 'stranger']) {
        await File(p.join(root.path, 'clips', '$n.mp3')).writeAsString('xxx');
      }
      final r = await prune(lib, root.path, {'fav'}, 1, '2026-10-10');
      expect(r, (kept: 3, freed: 3));
      final left = Directory(p.join(root.path, 'clips')).listSync().map((e) => p.basename(e.path)).toList()..sort();
      expect(left, ['fav.mp3', 'new.mp3', 'pin.mp3', 'stranger.mp3']);
      expect(lib.tracks.first.clipPresent, isFalse);
      expect(lib.tracks.first.clipBytes, isNull);
    });
  });
}
