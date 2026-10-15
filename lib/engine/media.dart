/// Everything that runs ffmpeg. Always argument arrays, never shell strings (hard requirement 6).
/// The path to the bundled ffmpeg is injected so tests can use the system one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

const int clipSeconds = 30;
const String clipBitrate = '128k';
const int clipChannels = 1;

class RunResult {
  RunResult({required this.code, required this.stdout, required this.stderr, required this.timedOut});

  /// Exit code; 124 when the process was killed on timeout, 127 when the executable is missing.
  final int code;
  final String stdout;
  final String stderr;
  final bool timedOut;
}

/// Run a program with a timeout; a hung process never discards a whole run's work.
Future<RunResult> runTool(String exe, List<String> args, {required Duration timeout, String? workingDirectory}) async {
  final Process proc;
  try {
    proc = await Process.start(exe, args, workingDirectory: workingDirectory);
  } on ProcessException catch (e) {
    // ENOENT and friends: the executable is not there (or cannot be started).
    return RunResult(code: 127, stdout: '', stderr: e.message, timedOut: false);
  }
  var timedOut = false;
  final timer = Timer(timeout, () {
    timedOut = true;
    proc.kill();
  });
  try {
    final out = utf8.decoder.bind(proc.stdout).join();
    final err = utf8.decoder.bind(proc.stderr).join();
    final code = await proc.exitCode;
    final stdout = await out;
    final stderr = await err;
    return RunResult(code: timedOut ? 124 : code, stdout: stdout, stderr: stderr, timedOut: timedOut);
  } finally {
    timer.cancel();
  }
}

String lastLine(String text, [String fallback = 'no output']) {
  final lines = text.trim().split(RegExp(r'\r?\n')).where((l) => l.isNotEmpty).toList();
  final line = lines.isEmpty ? fallback : lines.last;
  return line.length > 160 ? line.substring(0, 160) : line;
}

class MediaResult {
  MediaResult.ok()
      : ok = true,
        error = null;
  MediaResult.failed(this.error) : ok = false;

  final bool ok;
  final String? error;
}

/// A number the way JavaScript's String(n) prints it: 20 → "20", 20.5 → "20.5".
String _jsNumber(num n) => n is int || n == n.truncate() ? n.toInt().toString() : n.toString();

/// Cut the 30 s audition clip: mono, 44.1 kHz, 128k MP3, no metadata. Same ffmpeg arguments as ingest.py.
Future<MediaResult> makeClip(String ffmpeg, String src, String dest, num hookStart) async {
  await Directory(p.dirname(dest)).create(recursive: true);
  final res = await runTool(
    ffmpeg,
    ['-y', '-loglevel', 'error', '-ss', _jsNumber(hookStart), '-i', src, '-t', '$clipSeconds', '-ac', '$clipChannels', '-ar', '44100', '-b:a', clipBitrate, '-map_metadata', '-1', dest],
    timeout: const Duration(seconds: 120),
  );
  return _finish(res, dest);
}

class FullFormat {
  const FullFormat(this.args, this.ext);
  final List<String> args;
  final String ext;
}

const Map<String, FullFormat> fullFormats = {
  'wav24': FullFormat(['-c:a', 'pcm_s24le', '-ar', '48000', '-ac', '2'], 'wav'),
  'wav16': FullFormat(['-c:a', 'pcm_s16le', '-ar', '48000', '-ac', '2'], 'wav'),
  'mp3': FullFormat(['-c:a', 'libmp3lame', '-b:a', '320k', '-ar', '48000', '-ac', '2'], 'mp3'),
};

/// Transcode a full track for Resolve. Same arguments as promote.py.
Future<MediaResult> transcodeFull(String ffmpeg, String src, String dest, String format) async {
  final f = fullFormats[format] ?? fullFormats['wav16']!;
  await Directory(p.dirname(dest)).create(recursive: true);
  final res = await runTool(ffmpeg, ['-y', '-loglevel', 'error', '-i', src, ...f.args, '-map_metadata', '-1', dest], timeout: const Duration(seconds: 600));
  return _finish(res, dest);
}

/// A non-zero exit or an empty output file is a failure, and the output is removed.
Future<MediaResult> _finish(RunResult res, String dest) async {
  var size = 0;
  try {
    size = await File(dest).length();
  } catch (_) {
    size = 0;
  }
  if (res.code != 0 || size == 0) {
    try {
      await File(dest).delete();
    } catch (_) {}
    final err = res.stderr.trim();
    return MediaResult.failed(err.isEmpty ? 'ffmpeg exit ${res.code}' : (err.length > 200 ? err.substring(0, 200) : err));
  }
  return MediaResult.ok();
}

const int analysisSr = 22050;
const int analysisHop = 8192;
const int _frame = 2048;

class RmsSeries {
  RmsSeries({required this.rms, required this.hop, required this.duration});

  final Float32List rms;

  /// Seconds between two entries of [rms].
  final double hop;

  /// Seconds of audio that were decoded.
  final double duration;
}

/// Loudness series for the energy hook method: decode to mono 22.05 kHz floats and compute the
/// RMS of a 2048-sample frame centred on every 8192nd sample, the way librosa's rms() did.
Future<RmsSeries?> measureRms(String ffmpeg, String src) async {
  final bytes = await _runToolBinary(ffmpeg, ['-loglevel', 'error', '-i', src, '-ac', '1', '-ar', '$analysisSr', '-f', 'f32le', '-'], const Duration(seconds: 300));
  if (bytes == null) return null;
  final samples = _floatsLE(bytes);
  final n = samples.length;
  if (n == 0) return null;
  final frames = n ~/ analysisHop + 1;
  final rms = Float32List(frames);
  const half = _frame ~/ 2;
  for (var i = 0; i < frames; i++) {
    final centre = i * analysisHop;
    var sum = 0.0;
    for (var k = centre - half; k < centre + half; k++) {
      final v = k >= 0 && k < n ? samples[k] : 0.0;
      sum += v * v;
    }
    rms[i] = math.sqrt(sum / _frame);
  }
  return RmsSeries(rms: rms, hop: analysisHop / analysisSr, duration: n / analysisSr);
}

/// The f32le samples in `bytes` (a trailing partial sample is dropped).
Float32List _floatsLE(Uint8List bytes) {
  final n = bytes.lengthInBytes ~/ 4;
  if (Endian.host == Endian.little && bytes.offsetInBytes % 4 == 0) {
    return Float32List.view(bytes.buffer, bytes.offsetInBytes, n);
  }
  final data = ByteData.sublistView(bytes);
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = data.getFloat32(i * 4, Endian.little);
  }
  return out;
}

/// Run a program and collect its raw stdout; null on a non-zero exit, timeout or missing executable.
Future<Uint8List?> _runToolBinary(String exe, List<String> args, Duration timeout) async {
  final Process proc;
  try {
    proc = await Process.start(exe, args);
  } on ProcessException {
    return null;
  }
  var timedOut = false;
  final timer = Timer(timeout, () {
    timedOut = true;
    proc.kill();
  });
  try {
    final builder = BytesBuilder(copy: false);
    final collected = proc.stdout.forEach(builder.add);
    final drained = proc.stderr.drain<void>();
    final code = await proc.exitCode;
    await collected;
    await drained;
    if (timedOut || code != 0) return null;
    return builder.takeBytes();
  } finally {
    timer.cancel();
  }
}

/// Duration in seconds via ffprobe-less parsing: ask ffmpeg to decode nothing and read "Duration:".
Future<double?> probeDuration(String ffmpeg, String src) async {
  final res = await runTool(ffmpeg, ['-hide_banner', '-i', src, '-f', 'null', '-'], timeout: const Duration(seconds: 60));
  final m = RegExp(r'Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)').firstMatch(res.stderr);
  if (m == null) return null;
  return int.parse(m.group(1)!) * 3600 + int.parse(m.group(2)!) * 60 + double.parse(m.group(3)!);
}
