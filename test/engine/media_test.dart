// runTool, makeClip, measureRms and probeDuration against the system ffmpeg.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:soundbites/engine/media.dart';

const ffmpeg = '/usr/bin/ffmpeg';

void main() {
  group('runTool', () {
    test('captures stdout and the exit code', () async {
      final r = await runTool('/bin/echo', ['hello', 'world'], timeout: const Duration(seconds: 10));
      expect(r.code, 0);
      expect(r.stdout.trim(), 'hello world');
      expect(r.stderr, '');
      expect(r.timedOut, isFalse);
    });
    test('reports a missing executable as 127', () async {
      final r = await runTool('/nonexistent/tool', ['--version'], timeout: const Duration(seconds: 10));
      expect(r.code, 127);
      expect(r.timedOut, isFalse);
      expect(r.stderr, isNotEmpty);
    });
    test('kills a hung process on timeout (124)', () async {
      final r = await runTool('/bin/sleep', ['30'], timeout: const Duration(milliseconds: 300));
      expect(r.code, 124);
      expect(r.timedOut, isTrue);
    });
    test('passes a non-zero exit code through and honours the working directory', () async {
      final r = await runTool('/bin/sh', ['-c', 'pwd; exit 3'], timeout: const Duration(seconds: 10), workingDirectory: '/tmp');
      expect(r.code, 3);
      expect(r.stdout.trim(), '/tmp');
    });
    test('lastLine returns the last non-empty line, capped at 160 characters', () {
      expect(lastLine('a\nb\r\n\n'), 'b');
      expect(lastLine(''), 'no output');
      expect(lastLine('', 'nothing'), 'nothing');
      expect(lastLine('x' * 300).length, 160);
    });
  });

  group('ffmpeg', () {
    late Directory dir;
    late String src;
    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('sb-media-');
      src = p.join(dir.path, 'x.mp3');
      final r = await Process.run(ffmpeg, ['-y', '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=10', '-ac', '2', '-ar', '44100', src]);
      expect(r.exitCode, 0, reason: r.stderr.toString());
    });
    tearDownAll(() async {
      await dir.delete(recursive: true);
    });

    test('probeDuration reads the duration', () async {
      final d = await probeDuration(ffmpeg, src);
      expect(d, isNotNull);
      expect(d!, closeTo(10, 0.2));
      expect(await probeDuration(ffmpeg, p.join(dir.path, 'missing.mp3')), isNull);
    });

    test('makeClip writes the audition clip', () async {
      final dest = p.join(dir.path, 'clips', 'x-clip.mp3');
      final r = await makeClip(ffmpeg, src, dest, 2);
      expect(r.ok, isTrue, reason: r.error);
      expect(await File(dest).length(), greaterThan(1000));
      // 2 s in, up to 30 s long: the 10 s source leaves about 8 s.
      final d = await probeDuration(ffmpeg, dest);
      expect(d!, closeTo(8, 0.3));
    });

    test('makeClip fails cleanly on a missing source and leaves nothing behind', () async {
      final dest = p.join(dir.path, 'clips', 'nope.mp3');
      final r = await makeClip(ffmpeg, p.join(dir.path, 'missing.mp3'), dest, 0);
      expect(r.ok, isFalse);
      expect(r.error, isNotEmpty);
      expect(await File(dest).exists(), isFalse);
    });

    test('transcodeFull writes a wav and falls back to wav16 for an unknown format', () async {
      final dest = p.join(dir.path, 'full', 'x.wav');
      final r = await transcodeFull(ffmpeg, src, dest, 'bogus');
      expect(r.ok, isTrue, reason: r.error);
      // 16-bit stereo at 48 kHz for ~10 s is about 1.9 MB.
      expect(await File(dest).length(), greaterThan(1500000));
      expect(fullFormats.keys, ['wav24', 'wav16', 'mp3']);
      expect(fullFormats['mp3']!.ext, 'mp3');
    });

    test('measureRms returns a plausible loudness series', () async {
      final r = await measureRms(ffmpeg, src);
      expect(r, isNotNull);
      expect(r!.hop, analysisHop / analysisSr);
      expect(r.duration, closeTo(10, 0.2));
      // floor(n / 8192) + 1 frames for ~220500 samples.
      expect(r.rms.length, inInclusiveRange(26, 29));
      expect(r.rms.length, (r.duration * analysisSr).floor() ~/ analysisHop + 1);
      // A steady tone: every interior frame has about the same, non-zero loudness.
      final interior = r.rms.sublist(1, r.rms.length - 2);
      for (final v in interior) {
        expect(v, greaterThan(0.01));
        expect(v, lessThan(1.0));
      }
      final lo = interior.reduce((a, b) => a < b ? a : b), hi = interior.reduce((a, b) => a > b ? a : b);
      expect(hi / lo, lessThan(1.5));
      // The first frame is centred on sample 0, so only half of it holds signal: about 1/sqrt(2) of the rest.
      expect(r.rms[0], closeTo(interior.first * 0.707, interior.first * 0.1));
    });

    test('measureRms is null for a missing file', () async {
      expect(await measureRms(ffmpeg, p.join(dir.path, 'missing.mp3')), isNull);
    });
  });
}
