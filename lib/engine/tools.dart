/// yt-dlp and Deno are not bundled. This module downloads the official standalone builds into the
/// app-data folder, verifies them against the publisher's checksums, keeps them under versioned
/// file names (so a running yt-dlp.exe is never overwritten on Windows), and tells the caller
/// which one to run.
///
/// Only the pure, testable parts live here: checksum parsing, release-tag detection, file naming
/// and the verify step. The download itself takes a `fetch` so tests can hand in a fake; the
/// real one ([defaultFetch]) is built on package:http and follows redirects by hand so that the
/// final URL (which carries the release tag) is known.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' hide Platform;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// The desktop platforms the app ships on. `name` gives the Node-style id ('darwin' | 'win32').
enum Platform { darwin, win32 }

enum Arch { arm64, x64 }

enum ToolName {
  ytDlp('yt-dlp'),
  deno('deno');

  const ToolName(this.id);

  /// The tool's name as shown to the user and used in file names.
  final String id;
}

class ToolSpec {
  const ToolSpec({required this.name, required this.repo, required this.asset, required this.sums, this.zipEntry, required this.localBase});

  final ToolName name;

  /// The GitHub repo whose latest release we follow.
  final String repo;

  /// Release asset name for this platform/arch.
  final String asset;

  /// Checksum file name for this platform/arch.
  final String sums;

  /// Name inside the zip, if the asset is a zip.
  final String? zipEntry;

  /// What the installed file is called before the version suffix.
  final String localBase;
}

ToolSpec toolSpec(ToolName name, Platform platform, Arch arch) {
  if (name == ToolName.ytDlp) {
    return platform == Platform.darwin
        ? ToolSpec(name: name, repo: 'yt-dlp/yt-dlp', asset: 'yt-dlp_macos', sums: 'SHA2-256SUMS', localBase: 'yt-dlp')
        : ToolSpec(name: name, repo: 'yt-dlp/yt-dlp', asset: 'yt-dlp.exe', sums: 'SHA2-256SUMS', localBase: 'yt-dlp');
  }
  // Deno publishes one zip per target with a matching .sha256sum file next to it.
  final target = platform == Platform.darwin
      ? (arch == Arch.arm64 ? 'aarch64-apple-darwin' : 'x86_64-apple-darwin')
      : 'x86_64-pc-windows-msvc';
  final asset = 'deno-$target.zip';
  return ToolSpec(
    name: name,
    repo: 'denoland/deno',
    asset: asset,
    sums: '$asset.sha256sum',
    zipEntry: platform == Platform.win32 ? 'deno.exe' : 'deno',
    localBase: 'deno',
  );
}

String latestDownloadUrl(ToolSpec spec, String file) => 'https://github.com/${spec.repo}/releases/latest/download/$file';

/// Parse a checksum file into {fileName: lowercaseHexHash}. Handles both layouts we meet:
///   GNU style:          `<hash>  <name>` one per line (yt-dlp's SHA2-256SUMS, Deno on macOS)
///   PowerShell style:   `Algorithm : SHA256 / Hash : <HEX> / Path : C:\...\<name>` (Deno on Windows)
Map<String, String> parseChecksums(String text) {
  final out = <String, String>{};
  final lines = text.split(RegExp(r'\r?\n'));

  // PowerShell Get-FileHash layout
  final ps = RegExp(r'^\s*(Algorithm|Hash|Path)\s*:\s*(.+?)\s*$');
  String? psHash;
  for (final line in lines) {
    final m = ps.firstMatch(line);
    if (m == null) continue;
    if (m.group(1) == 'Hash') psHash = m.group(2)!.toLowerCase();
    if (m.group(1) == 'Path' && psHash != null) {
      final name = m.group(2)!.split(RegExp(r'[\\/]')).last;
      out[name] = psHash;
      psHash = null;
    }
  }

  // GNU layout (also "hash *name" for binary mode)
  final gnu = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(\S.*?)\s*$');
  for (final line in lines) {
    final m = gnu.firstMatch(line);
    if (m != null) out[m.group(2)!] = m.group(1)!.toLowerCase();
  }
  return out;
}

Future<String> sha256File(String path) async {
  final digest = await sha256.bind(File(path).openRead()).first;
  return digest.toString();
}

/// The release tag from a resolved GitHub download URL, e.g. ".../releases/download/2026.08.19/yt-dlp_macos" → "2026.08.19".
String? tagFromDownloadUrl(String url) {
  final m = RegExp(r'/releases/download/([^/]+)/').firstMatch(url);
  return m == null ? null : Uri.decodeComponent(m.group(1)!);
}

/// Versioned local file name: yt-dlp-2026.08.19, yt-dlp-2026.08.19.exe, deno-v2.9.7 ...
String versionedFileName(ToolSpec spec, String tag, Platform platform) {
  final safeTag = tag.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
  return '${spec.localBase}-$safeTag${platform == Platform.win32 ? '.exe' : ''}';
}

/// Pick the newest installed build of a tool from the files in the tools folder.
String? pickInstalled(List<String> files, ToolSpec spec, Platform platform) {
  final suffix = platform == Platform.win32 ? r'\.exe' : '';
  final re = RegExp('^${RegExp.escape(spec.localBase)}-(.+?)$suffix\$');
  final tagged = <({String f, String tag})>[];
  for (final f in files) {
    final m = re.firstMatch(f);
    if (m != null && !f.endsWith('.part')) tagged.add((f: f, tag: m.group(1)!));
  }
  if (tagged.isEmpty) return null;
  tagged.sort((a, b) => compareTags(b.tag, a.tag));
  return tagged.first.f;
}

/// Compare release tags like "2026.08.19" / "v2.9.7" numerically segment by segment.
int compareTags(String a, String b) {
  List<int> parts(String s) =>
      s.replaceFirst(RegExp(r'^v'), '').split(RegExp(r'[^0-9]+')).where((x) => x.isNotEmpty).map(int.parse).toList();
  final pa = parts(a), pb = parts(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final d = (i < pa.length ? pa[i] : 0) - (i < pb.length ? pb[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

/// What a fetch hands back: enough of the Fetch API for [installLatest]. `url` is the final URL
/// after redirects and `redirects` every URL visited on the way there, oldest first (empty when
/// the fetch does not know). GitHub's "latest/download" link redirects to
/// `.../releases/download/<tag>/<asset>` and from there on to a signed asset host, so the tag we
/// are after sits in the chain rather than in the final URL. Read either `text()` or `body`, not both.
class FetchResponse {
  FetchResponse({required this.ok, required this.status, required this.url, this.redirects = const [], required Future<String> Function() text, this.body})
      : _text = text; // ignore: prefer_initializing_formals

  final bool ok;
  final int status;
  final String url;
  final List<String> redirects;
  final Stream<List<int>>? body;
  final Future<String> Function() _text;

  Future<String> text() => _text();
}

typedef FetchLike = Future<FetchResponse> Function(String url);

/// The maximum number of redirects [defaultFetch] follows.
const int maxRedirects = 10;

/// GET a URL with package:http, following redirects by hand (at most [maxRedirects] hops) so that
/// the final URL is known. Network failures surface as [ToolDownloadError] with code `network`.
Future<FetchResponse> defaultFetch(String url) async {
  final client = http.Client();
  var uri = Uri.parse(url);
  final visited = <String>[];
  try {
    for (var hop = 0;; hop++) {
      final req = http.Request('GET', uri)
        ..followRedirects = false
        ..headers['User-Agent'] = 'Soundbites';
      final res = await client.send(req);
      final location = res.headers['location'];
      final redirect = const {301, 302, 303, 307, 308}.contains(res.statusCode);
      if (redirect && location != null && hop < maxRedirects) {
        await res.stream.drain<void>();
        visited.add(uri.toString());
        uri = uri.resolve(location);
        continue;
      }
      final ok = res.statusCode >= 200 && res.statusCode < 300;
      // Close the client once the body has been read (or the caller gave up on it).
      final controller = StreamController<List<int>>();
      res.stream.listen(controller.add, onError: controller.addError, onDone: () {
        controller.close();
        client.close();
      }, cancelOnError: true);
      controller.onCancel = () => client.close();
      final body = controller.stream;
      return FetchResponse(ok: ok, status: res.statusCode, url: uri.toString(), redirects: visited, text: () => utf8.decodeStream(body), body: body);
    }
  } on ToolDownloadError {
    client.close();
    rethrow;
  } catch (e) {
    client.close();
    throw ToolDownloadError('$e', ToolDownloadErrorCode.network);
  }
}

enum ToolDownloadErrorCode {
  network('network'),
  checksumMissing('checksum-missing'),
  checksumMismatch('checksum-mismatch'),
  noTag('no-tag'),
  zip('zip');

  const ToolDownloadErrorCode(this.id);
  final String id;
}

class ToolDownloadError implements Exception {
  ToolDownloadError(this.message, this.code);

  final String message;
  final ToolDownloadErrorCode code;

  @override
  String toString() => 'ToolDownloadError(${code.id}): $message';
}

typedef ExtractZipEntry = Future<void> Function(String zipPath, String entry, String dest);

class InstallResult {
  InstallResult({required this.path, required this.tag, required this.alreadyPresent});

  /// Absolute path of the installed executable.
  final String path;
  final String tag;
  final bool alreadyPresent;
}

/// Download the latest release of a tool into `toolsDir`, verify it and install it under a
/// versioned name. Returns the absolute path of the installed executable. Never touches an
/// existing file of the same version (so a running .exe is never replaced), and only switches
/// callers over once the checksum has passed. `extractZipEntry` is injected because zip handling
/// lives in its own module (`zip.dart`); without it a zip asset fails with code `zip`.
///
/// Throws [ToolDownloadError]; any other failure of `fetch` or the file system is reported as
/// a `network` error so callers have one type to catch.
Future<InstallResult> installLatest(
  ToolSpec spec,
  Platform platform,
  String toolsDir, {
  required FetchLike fetch,
  ExtractZipEntry? extractZipEntry,
}) async {
  try {
    return await _installLatest(spec, platform, toolsDir, fetch, extractZipEntry);
  } on ToolDownloadError {
    rethrow;
  } catch (e) {
    throw ToolDownloadError('$e', ToolDownloadErrorCode.network);
  }
}

Future<InstallResult> _installLatest(ToolSpec spec, Platform platform, String toolsDir, FetchLike fetch, ExtractZipEntry? extractZipEntry) async {
  await Directory(toolsDir).create(recursive: true);

  // 1. Resolve the tag: follow the redirect of the "latest" URL and read the tag from it.
  final sumsRes = await fetch(latestDownloadUrl(spec, spec.sums));
  if (!sumsRes.ok) throw ToolDownloadError('Could not fetch checksums for ${spec.name.id} (HTTP ${sumsRes.status})', ToolDownloadErrorCode.network);
  final tag = _tagFromResponse(sumsRes);
  if (tag == null) throw ToolDownloadError('Could not tell which ${spec.name.id} version is current', ToolDownloadErrorCode.noTag);
  final sums = parseChecksums(await sumsRes.text());
  final expected = sums[spec.asset];
  if (expected == null) throw ToolDownloadError('Checksum list for ${spec.name.id} does not mention ${spec.asset}', ToolDownloadErrorCode.checksumMissing);

  final finalName = versionedFileName(spec, tag, platform);
  final finalPath = p.join(toolsDir, finalName);
  if (await File(finalPath).exists()) return InstallResult(path: finalPath, tag: tag, alreadyPresent: true);

  // 2. Download the asset for that exact tag to a .part file.
  final assetUrl = 'https://github.com/${spec.repo}/releases/download/${Uri.encodeComponent(tag)}/${spec.asset}';
  final part = p.join(toolsDir, '${spec.asset}-$tag.part');
  final res = await fetch(assetUrl);
  final body = res.body;
  if (!res.ok || body == null) throw ToolDownloadError('Could not download ${spec.asset} (HTTP ${res.status})', ToolDownloadErrorCode.network);
  await _rm(part);
  final handle = await File(part).open(mode: FileMode.write);
  try {
    await for (final chunk in body) {
      await handle.writeFrom(chunk);
    }
    await handle.flush();
  } finally {
    await handle.close();
  }

  // 3. Verify before anything is renamed into place.
  final actual = await sha256File(part);
  if (actual != expected) {
    await _rm(part);
    throw ToolDownloadError('${spec.asset} did not match its published checksum and was discarded', ToolDownloadErrorCode.checksumMismatch);
  }

  // 4. Install: unzip the single entry, or rename the binary. Mark executable on macOS.
  final zipEntry = spec.zipEntry;
  if (zipEntry != null) {
    if (extractZipEntry == null) throw ToolDownloadError('No zip extractor available', ToolDownloadErrorCode.zip);
    final tmpOut = '$finalPath.extracting';
    await _rm(tmpOut);
    await extractZipEntry(part, zipEntry, tmpOut);
    await File(tmpOut).rename(finalPath);
    await _rm(part);
  } else {
    await File(part).rename(finalPath);
  }
  if (platform != Platform.win32) await Process.run('chmod', ['755', finalPath]);
  return InstallResult(path: finalPath, tag: tag, alreadyPresent: false);
}

/// The release tag from the final URL, or failing that from any redirect on the way to it.
String? _tagFromResponse(FetchResponse res) =>
    tagFromDownloadUrl(res.url) ?? res.redirects.reversed.map(tagFromDownloadUrl).nonNulls.firstOrNull;

Future<void> _rm(String path) async {
  try {
    await File(path).delete();
  } on FileSystemException {
    // force: true — a missing file is fine.
  }
}

/// Base name helper exported for the Needs-attention wording ("yt-dlp-2026.08.19 has gone missing").
String displayName(String path) => p.basename(path);
