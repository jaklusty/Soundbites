// Phase 1 checks (b) and (c): the Dart ingest against the original Python on two copies of
// the real library. Needs python3 and ffmpeg on PATH and the copies prepared by
// scripts/prepare-parity.sh. Skipped unless SOUNDBITES_PARITY points at the folder holding
// py/ and dart/ copies and audio/ test files.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:soundbites/engine/ingest.dart';
import 'package:soundbites/engine/library.dart';
import 'package:soundbites/engine/media.dart';
import 'package:soundbites/engine/store.dart';

void main() {
  final base = Platform.environment['SOUNDBITES_PARITY'];
  final py = p.join(base ?? '', 'py');
  final dart = p.join(base ?? '', 'dart');
  final audio = p.join(base ?? '', 'audio');
  final ffmpeg = Platform.environment['FFMPEG'] ?? 'ffmpeg';
  const run = '2026-10-10';

  final raw = <Json>[
    {'title': 'Local One', 'artist': 'Test Artist', 'local': p.join(audio, 'local1.mp3'), 'hook_start': '0:30', 'direction': 'rising', 'uses': 1000, 'bpm': 120, 'energy': 'high', 'mood': ['driving'], 'suits': 'a test', 'licence': 'platform', 'notes': 'parity'},
    {'title': 'Déjà Vu (Live)', 'artist': 'Beyoncé', 'local': p.join(audio, 'local2.mp3'), 'hook_start': 45, 'direction': 'peaking', 'mood': ['pop']},
    {'title': 'Time', 'artist': 'Hans Zimmer', 'local': p.join(audio, 'local3.mp3'), 'hook_start': '0:10', 'direction': 'peaking', 'uses': 5},
    {'title': 'Missing Audio', 'artist': 'Nobody', 'local': p.join(audio, 'does-not-exist.mp3'), 'direction': 'fading'},
    {'title': 'local one', 'artist': 'TEST ARTIST', 'local': p.join(audio, 'local1.mp3')},
  ];
  List<Candidate> cands() => raw.map((r) => normalizeCandidate(r, CandidateSource.pending)).whereType<Candidate>().toList();

  Future<String> writeCandidates(String dir) async {
    final file = File(p.join(dir, 'pending', '$run.json'));
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert({'run': run, 'candidates': raw}));
    return file.path;
  }

  Future<Json> readJson(String path) async => jsonDecode(await File(path).readAsString()) as Json;

  test('(b) dry run prints the same counts as ingest.py --dry-run', () async {
    final file = await writeCandidates(py);
    final res = await Process.run('python3', ['-I', p.join(py, 'ingest.py'), file, '--root', py, '--dry-run']);
    final line = (res.stderr as String).trim().split('\n').last;
    final m = RegExp(r'dry run \((\S+)\): (\d+) candidates, (\d+) new, (\d+) already known, keep-runs (\d+)(?:, (\d+) DUPLICATE ids)?').firstMatch(line);
    expect(m, isNotNull, reason: line);
    final library = Library(await readJson(p.join(dart, 'library.json')));
    final mine = dryRun(library, cands(), run, 8);
    expect([mine.run, mine.candidates, mine.fresh, mine.known, mine.keepRuns, mine.duplicateIds], [m![1], int.parse(m[2]!), int.parse(m[3]!), int.parse(m[4]!), int.parse(m[5]!), int.parse(m[6] ?? '0')]);
  }, skip: base == null ? 'set SOUNDBITES_PARITY to run' : false);

  test('(c) a real local-audio ingest leaves the same library.json and clips/', () async {
    final file = await writeCandidates(py);
    final res = await Process.run('python3', ['-I', p.join(py, 'ingest.py'), file, '--root', py, '--keep-runs', '1']);
    expect(res.exitCode, anyOf(0, 2), reason: res.stderr as String);

    final result = await runIngest(
      Store(dart),
      run,
      cands(),
      IngestDeps(
        resolve: (_, _) async => null,
        inspect: (_) async => null,
        download: (_, _) async => null,
        clip: (src, dest, at) async {
          final r = await makeClip(ffmpeg, src, dest, at);
          return (ok: r.ok, error: r.error);
        },
      ),
      keepRuns: 1,
    );

    Json norm(Json lib) {
      final copy = jsonDecode(jsonEncode(lib)) as Json;
      copy.remove('updated');
      for (final t in (copy['tracks'] as List).cast<Json>()) {
        if (t['hook_detail'] == 'set in candidates.json' || t['hook_detail'] == 'set in the run file') t['hook_detail'] = 'explicit';
      }
      return copy;
    }

    expect(norm(await readJson(p.join(dart, 'library.json'))), norm(await readJson(p.join(py, 'library.json'))));

    Future<Map<String, int>> listing(String dir) async {
      final out = <String, int>{};
      final files = await Directory(p.join(dir, 'clips')).list().toList();
      files.sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        out[p.basename(f.path)] = await File(f.path).length();
      }
      return out;
    }

    expect(await listing(dart), await listing(py));

    final pyLast = await readJson(p.join(py, 'last_run.json'))..remove('finished');
    final dartLast = await readJson(p.join(dart, 'last_run.json'))..remove('finished');
    expect(dartLast, pyLast);
    expect(result.noAudio, 1);

    List<List<Object?>> kinds(Json h) => (h['events'] as List).cast<Json>().map((e) => [e['kind'], e['ok']]).toList();
    expect(kinds(await readJson(p.join(dart, 'health.json'))), kinds(await readJson(p.join(py, 'health.json'))));
  }, skip: base == null ? 'set SOUNDBITES_PARITY to run' : false);
}
