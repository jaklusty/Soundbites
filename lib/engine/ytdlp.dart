/// Everything that runs yt-dlp. Argument arrays only, "--" before every URL, bundled ffmpeg via
/// --ffmpeg-location, Deno via --js-runtimes, no remote components, no browser cookies.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'library.dart';
import 'media.dart';

class YtDlpPaths {
  const YtDlpPaths({required this.ytdlp, this.deno, required this.ffmpeg});

  final String ytdlp;
  final String? deno;
  final String ffmpeg;
}

class YtDlpOptions {
  const YtDlpOptions({required this.paths, required this.sleepRequests, this.log, this.onExtractorFailure});

  final YtDlpPaths paths;

  /// Seconds to sleep between requests (yt-dlp --sleep-requests).
  final num sleepRequests;
  final void Function(String line)? log;

  /// Called when stderr looks like an extractor failure (a stale yt-dlp).
  final void Function(String detail)? onExtractorFailure;
}

/// A search result or an inspected URL: the upload the track resolves to.
class ResolvedUpload {
  const ResolvedUpload({required this.videoId, required this.url, required this.title, required this.channel, this.duration});

  final String videoId;
  final String url;
  final String title;
  final String channel;

  /// Seconds, or null when yt-dlp printed "NA" (or nothing).
  final double? duration;

  @override
  bool operator ==(Object other) =>
      other is ResolvedUpload && other.videoId == videoId && other.url == url && other.title == title && other.channel == channel && other.duration == duration;

  @override
  int get hashCode => Object.hash(videoId, url, title, channel, duration);

  @override
  String toString() => 'ResolvedUpload($videoId, $title, $channel, $duration)';
}

class DownloadedSource {
  const DownloadedSource({required this.path, this.info});

  /// Path of the downloaded (or local) audio file.
  final String path;

  /// yt-dlp info dict (heatmap, duration, title, channel, uploader, id), when there is one.
  final Json? info;
}

const Duration searchTimeout = Duration(milliseconds: 120000);
const Duration downloadTimeout = Duration(milliseconds: 180000);
const Duration fullTimeout = Duration(milliseconds: 600000);

/// Signs in stderr that yt-dlp itself is out of date rather than the track being unavailable.
final RegExp extractorFailure = RegExp(
  r'Unable to extract|Signature extraction failed|nsig extraction failed|Requested format is not available|Sign in to confirm|HTTP Error 403|Precondition check failed|player response|Failed to parse JSON|challenge solver|js runtime',
  caseSensitive: false,
);

List<String> baseArgs(YtDlpOptions o) {
  final args = ['--no-warnings', '--no-playlist', '--no-remote-components', '--retries', '3', '--socket-timeout', '20', '--ffmpeg-location', o.paths.ffmpeg];
  final deno = o.paths.deno;
  if (deno != null) args.addAll(['--js-runtimes', 'deno:$deno']);
  if (o.sleepRequests > 0) args.addAll(['--sleep-requests', _jsNumber(o.sleepRequests)]);
  return args;
}

/// A number the way JavaScript's String(n) prints it: 2 → "2", 2.5 → "2.5".
String _jsNumber(num n) => n is int || n == n.truncate() ? n.toInt().toString() : n.toString();

/// Sanitise a search query the way the Python did: strip control characters, cap length.
String cleanQuery(String q) {
  final s = q.replaceAll(RegExp(r'[\x00-\x1f]'), ' ').trim();
  return s.length > 200 ? s.substring(0, 200) : s;
}

const String _print = r'%(id)s\t%(title)s\t%(channel,uploader)s\t%(duration)s';

List<ResolvedUpload> parsePrintLines(String stdout) {
  final out = <ResolvedUpload>[];
  for (final line in stdout.split(RegExp(r'\r?\n'))) {
    final cols = line.split('\t');
    final id = cols.isNotEmpty ? cols[0].trim() : '';
    if (id.isEmpty || !ytId.hasMatch(id)) continue;
    final title = cols.length > 1 ? cols[1] : '';
    final channel = cols.length > 2 ? cols[2] : '';
    final d = cols.length > 3 ? double.tryParse(cols[3].trim()) : null;
    out.add(ResolvedUpload(
      videoId: id,
      url: 'https://www.youtube.com/watch?v=$id',
      title: title.trim(),
      channel: channel.replaceFirst(RegExp(r'^NA$'), '').trim(),
      duration: d != null && d.isFinite && d > 0 ? d : null,
    ));
  }
  return out;
}

/// "artist title" → the first of the top search results that is not rejected.
Future<ResolvedUpload?> resolveSearch(YtDlpOptions o, String query, List<String> rejected) async {
  final q = cleanQuery(query);
  if (q.isEmpty) return null;
  final n = 3 + rejected.length < 10 ? 3 + rejected.length : 10;
  final res = await runTool(o.paths.ytdlp, [...baseArgs(o), '--skip-download', '--flat-playlist', '--print', _print, '--', 'ytsearch$n:$q'], timeout: searchTimeout);
  if (res.code != 0) {
    final tail = lastLine(res.stderr);
    o.log?.call('  · search ${jsonEncode(q)} failed: $tail');
    if (extractorFailure.hasMatch(res.stderr)) o.onExtractorFailure?.call(tail);
    return null;
  }
  final found = parsePrintLines(res.stdout).where((u) => !rejected.contains(u.videoId)).toList();
  if (found.isEmpty) o.log?.call('  · search ${jsonEncode(q)} found nothing new');
  return found.isEmpty ? null : found.first;
}

/// Title, channel and duration for a known URL, without downloading.
Future<ResolvedUpload?> inspect(YtDlpOptions o, String url) async {
  final res = await runTool(o.paths.ytdlp, [...baseArgs(o), '--skip-download', '--print', _print, '--', url], timeout: searchTimeout);
  if (res.code != 0) {
    if (extractorFailure.hasMatch(res.stderr)) o.onExtractorFailure?.call(lastLine(res.stderr));
    return null;
  }
  final found = parsePrintLines(res.stdout);
  return found.isEmpty ? null : found.first;
}

/// Best audio into `workdir/src.<ext>`, with the info JSON (heatmap, duration) alongside. One attempt; no cookies.
Future<DownloadedSource?> downloadAudio(YtDlpOptions o, String url, String workdir, {Duration timeout = downloadTimeout}) async {
  await Directory(workdir).create(recursive: true);
  final out = p.join(workdir, 'src.%(ext)s');
  final res = await runTool(o.paths.ytdlp, [...baseArgs(o), '-f', 'bestaudio', '--write-info-json', '-o', out, '--', url], timeout: timeout);
  final files = (await _readdir(workdir)).where((f) => f.startsWith('src.') && !f.endsWith('.json')).toList()..sort();
  if (res.code != 0 || files.isEmpty) {
    final tail = lastLine(res.stderr);
    o.log?.call('  · download failed: $tail');
    if (extractorFailure.hasMatch(res.stderr)) o.onExtractorFailure?.call(tail);
    return null;
  }
  Json? info;
  final infoFile = (await _readdir(workdir)).where((f) => f.endsWith('.info.json')).firstOrNull;
  if (infoFile != null) {
    try {
      final parsed = jsonDecode(await File(p.join(workdir, infoFile)).readAsString());
      info = parsed is Map ? parsed.cast<String, dynamic>() : null;
    } catch (_) {
      info = null;
    }
  }
  return DownloadedSource(path: p.join(workdir, files.first), info: info);
}

/// The whole track for promotion.
Future<DownloadedSource?> downloadFull(YtDlpOptions o, String url, String workdir) async {
  await Directory(workdir).create(recursive: true);
  final out = p.join(workdir, 'full.%(ext)s');
  final res = await runTool(o.paths.ytdlp, [...baseArgs(o), '-f', 'bestaudio', '-o', out, '--', url], timeout: fullTimeout);
  final files = (await _readdir(workdir)).where((f) => f.startsWith('full.')).toList()..sort();
  if (res.code != 0 || files.isEmpty) {
    final tail = lastLine(res.stderr);
    o.log?.call('  · full download failed: $tail');
    if (extractorFailure.hasMatch(res.stderr)) o.onExtractorFailure?.call(tail);
    return null;
  }
  return DownloadedSource(path: p.join(workdir, files.first));
}

/// "yt-dlp --version" → "2026.08.19", or null if it does not run.
Future<String?> version(String ytdlp) async {
  final res = await runTool(ytdlp, ['--version'], timeout: const Duration(seconds: 30));
  final v = res.stdout.trim().split(RegExp(r'\s+')).first;
  return res.code == 0 && v.isNotEmpty ? v : null;
}

Future<List<String>> _readdir(String dir) => Directory(dir).list().map((e) => p.basename(e.path)).toList();
