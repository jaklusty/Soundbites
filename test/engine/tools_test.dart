// Port of electron/test/tools.test.ts, plus a real-zip case for zip.dart.
import 'dart:convert';
import 'dart:io' hide Platform;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:soundbites/engine/tools.dart';
import 'package:soundbites/engine/zip.dart';

const gnu = '1fa6733c37ea6fb51c99ad8fe785e7b7e5f3246c9b980230329d4fb72ed8d4d6  yt-dlp\n'
    '66674953fe251b89f4d08c5f0e35e0728679bd67ab3d7d05c0562af101dd3e7a  yt-dlp.exe\n'
    '0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202  yt-dlp_macos\n';
const ps = '\n\nAlgorithm : SHA256\n'
    'Hash      : A0C3101B4158D1DFB7D6A78A7BF0F3DE80C96BB423C152BEEC8BEB22786F2238\n'
    'Path      : C:\\a\\deno\\deno\\target\\release\\deno-x86_64-pc-windows-msvc.zip\n\n';
const denoMac = '5cd46d6268f6f78f5d88bdc7159d20bd44cdaa4b3303474839f87ec6fe7ae25c  deno-aarch64-apple-darwin.zip\n';

void main() {
  group('checksum parsing', () {
    test('reads GNU-style sums (yt-dlp SHA2-256SUMS)', () {
      final m = parseChecksums(gnu);
      expect(m['yt-dlp_macos'], '0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202');
      expect(m['yt-dlp.exe'], '66674953fe251b89f4d08c5f0e35e0728679bd67ab3d7d05c0562af101dd3e7a');
      expect(m.length, 3);
    });
    test('reads PowerShell Get-FileHash layout (Deno on Windows), lower-casing the hash', () {
      final m = parseChecksums(ps);
      expect(m['deno-x86_64-pc-windows-msvc.zip'], 'a0c3101b4158d1dfb7d6a78a7bf0f3de80c96bb423c152beec8beb22786f2238');
    });
    test('reads the single-line Deno macOS layout', () {
      expect(parseChecksums(denoMac)['deno-aarch64-apple-darwin.zip'], startsWith('5cd46d'));
    });
    test('handles CRLF and binary-mode asterisks', () {
      final m = parseChecksums('${'ab' * 32} *file.bin\r\n');
      expect(m['file.bin'], 'ab' * 32);
    });
  });

  group('tags and names', () {
    test('extracts the tag from a resolved download URL', () {
      expect(tagFromDownloadUrl('https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/SHA2-256SUMS'), '2026.08.19');
      expect(tagFromDownloadUrl('https://github.com/denoland/deno/releases/download/v2.9.7/deno-aarch64-apple-darwin.zip.sha256sum'), 'v2.9.7');
      expect(tagFromDownloadUrl('https://github.com/x/y/releases/latest/download/f'), isNull);
    });
    test('builds versioned names per platform', () {
      expect(versionedFileName(toolSpec(ToolName.ytDlp, Platform.darwin, Arch.arm64), '2026.08.19', Platform.darwin), 'yt-dlp-2026.08.19');
      expect(versionedFileName(toolSpec(ToolName.ytDlp, Platform.win32, Arch.x64), '2026.08.19', Platform.win32), 'yt-dlp-2026.08.19.exe');
      expect(versionedFileName(toolSpec(ToolName.deno, Platform.win32, Arch.x64), 'v2.9.7', Platform.win32), 'deno-v2.9.7.exe');
    });
    test('picks the newest installed build and ignores partial downloads', () {
      final files = ['yt-dlp-2026.07.01', 'yt-dlp-2026.08.19', 'yt-dlp-2026.09.02.part', 'deno-v2.9.7', 'notes.txt'];
      expect(pickInstalled(files, toolSpec(ToolName.ytDlp, Platform.darwin, Arch.arm64), Platform.darwin), 'yt-dlp-2026.08.19');
      expect(pickInstalled(['yt-dlp-2026.08.19.exe', 'yt-dlp-2026.09.02.exe'], toolSpec(ToolName.ytDlp, Platform.win32, Arch.x64), Platform.win32), 'yt-dlp-2026.09.02.exe');
      expect(pickInstalled([], toolSpec(ToolName.deno, Platform.darwin, Arch.arm64), Platform.darwin), isNull);
    });
    test('compares tags numerically', () {
      expect(compareTags('2026.08.19', '2026.07.01'), greaterThan(0));
      expect(compareTags('v2.10.0', 'v2.9.7'), greaterThan(0));
      expect(compareTags('v2.9.7', 'v2.9.7'), 0);
    });
    test('deno asset names follow the platform', () {
      expect(toolSpec(ToolName.deno, Platform.darwin, Arch.arm64).asset, 'deno-aarch64-apple-darwin.zip');
      expect(toolSpec(ToolName.deno, Platform.darwin, Arch.x64).asset, 'deno-x86_64-apple-darwin.zip');
      expect(toolSpec(ToolName.deno, Platform.win32, Arch.x64).asset, 'deno-x86_64-pc-windows-msvc.zip');
      expect(toolSpec(ToolName.deno, Platform.win32, Arch.x64).zipEntry, 'deno.exe');
    });
  });

  group('installLatest', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sb-tools-');
    });
    tearDown(() async {
      await dir.delete(recursive: true);
    });

    FetchLike fakeFetch(Map<String, Object> files, String tag) {
      return (url) async {
        final name = url.split('/').last;
        final resolved = url.replaceFirst('/releases/latest/download/', '/releases/download/$tag/');
        final body = files[name];
        if (body == null) {
          return FetchResponse(ok: false, status: 404, url: resolved, text: () async => '', body: null);
        }
        final bytes = body is String ? Uint8List.fromList(utf8.encode(body)) : body as Uint8List;
        return FetchResponse(ok: true, status: 200, url: resolved, text: () async => utf8.decode(bytes), body: Stream.value(bytes));
      };
    }

    Future<List<String>> readdir() async => (await dir.list().map((e) => p.basename(e.path)).toList())..sort();

    test('downloads, verifies and installs under a versioned name, then is idempotent', () async {
      final bin = Uint8List.fromList(utf8.encode('#!/bin/sh\necho yt-dlp\n'));
      final hash = sha256.convert(bin).toString();
      final spec = toolSpec(ToolName.ytDlp, Platform.darwin, Arch.arm64);
      final f = fakeFetch({'SHA2-256SUMS': '$hash  yt-dlp_macos\n', 'yt-dlp_macos': bin}, '2026.08.19');
      final r = await installLatest(spec, Platform.darwin, dir.path, fetch: f);
      expect(r.tag, '2026.08.19');
      expect(r.alreadyPresent, isFalse);
      expect(r.path, p.join(dir.path, 'yt-dlp-2026.08.19'));
      final st = await File(r.path).stat();
      expect(st.mode & 0x49, isNot(0)); // 0o111: executable
      expect((await readdir()).where((n) => n.endsWith('.part')), isEmpty);
      final again = await installLatest(spec, Platform.darwin, dir.path, fetch: f);
      expect(again.alreadyPresent, isTrue);
      expect(again.path, r.path);
    });

    test('discards a download whose checksum does not match and installs nothing', () async {
      final spec = toolSpec(ToolName.ytDlp, Platform.win32, Arch.x64);
      final f = fakeFetch({'SHA2-256SUMS': '${'0' * 64}  yt-dlp.exe\n', 'yt-dlp.exe': 'MZ fake'}, '2026.08.19');
      await expectLater(
        installLatest(spec, Platform.win32, dir.path, fetch: f),
        throwsA(isA<ToolDownloadError>().having((e) => e.code, 'code', ToolDownloadErrorCode.checksumMismatch)),
      );
      expect(await readdir(), isEmpty);
    });

    test('fails clearly when the checksum list lacks the asset', () async {
      final spec = toolSpec(ToolName.ytDlp, Platform.darwin, Arch.x64);
      final f = fakeFetch({'SHA2-256SUMS': '${'0' * 64}  yt-dlp\n'}, '2026.08.19');
      await expectLater(
        installLatest(spec, Platform.darwin, dir.path, fetch: f),
        throwsA(isA<ToolDownloadError>().having((e) => e.code, 'code', ToolDownloadErrorCode.checksumMissing)),
      );
    });

    test('reports a missing checksum file as a network error and no tag as no-tag', () async {
      final spec = toolSpec(ToolName.ytDlp, Platform.darwin, Arch.x64);
      await expectLater(
        installLatest(spec, Platform.darwin, dir.path, fetch: fakeFetch({}, '2026.08.19')),
        throwsA(isA<ToolDownloadError>().having((e) => e.code, 'code', ToolDownloadErrorCode.network)),
      );
      // A fetch whose final URL is not a release download URL (no redirect happened).
      Future<FetchResponse> noRedirect(String url) async => FetchResponse(ok: true, status: 200, url: url, text: () async => gnu, body: null);
      await expectLater(
        installLatest(spec, Platform.darwin, dir.path, fetch: noRedirect),
        throwsA(isA<ToolDownloadError>().having((e) => e.code, 'code', ToolDownloadErrorCode.noTag)),
      );
    });

    test('reads the tag from the redirect chain when the final URL is a signed asset host', () async {
      final bin = Uint8List.fromList(utf8.encode('yt-dlp'));
      final hash = sha256.convert(bin).toString();
      final spec = toolSpec(ToolName.ytDlp, Platform.darwin, Arch.arm64);
      Future<FetchResponse> github(String url) async {
        final name = url.split('/').last;
        final tagged = url.replaceFirst('/releases/latest/download/', '/releases/download/2026.09.02/');
        final text = name == 'SHA2-256SUMS' ? '$hash  yt-dlp_macos\n' : 'yt-dlp';
        return FetchResponse(
          ok: true,
          status: 200,
          url: 'https://release-assets.githubusercontent.com/github-production-release-asset/1/2?sig=x&filename=$name',
          redirects: [url, tagged],
          text: () async => text,
          body: Stream.value(Uint8List.fromList(utf8.encode(text))),
        );
      }

      final r = await installLatest(spec, Platform.darwin, dir.path, fetch: github);
      expect(r.tag, '2026.09.02');
      expect(await readdir(), ['yt-dlp-2026.09.02']);
    });

    test('unzips the single Deno entry through the injected extractor', () async {
      final zipBytes = Uint8List.fromList(utf8.encode('PK fake zip'));
      final hash = sha256.convert(zipBytes).toString();
      final spec = toolSpec(ToolName.deno, Platform.win32, Arch.x64);
      final f = fakeFetch({
        'deno-x86_64-pc-windows-msvc.zip.sha256sum': 'Algorithm : SHA256\nHash      : ${hash.toUpperCase()}\nPath      : C:\\x\\deno-x86_64-pc-windows-msvc.zip\n',
        'deno-x86_64-pc-windows-msvc.zip': zipBytes,
      }, 'v2.9.7');
      final extracted = <String>[];
      final r = await installLatest(spec, Platform.win32, dir.path, fetch: f, extractZipEntry: (zip, entry, dest) async {
        extracted.add(entry);
        await File(dest).writeAsString('deno binary');
      });
      expect(extracted, ['deno.exe']);
      expect(r.path, p.join(dir.path, 'deno-v2.9.7.exe'));
      expect(await File(r.path).readAsString(), 'deno binary');
      expect(await readdir(), ['deno-v2.9.7.exe']);
    });

    test('a zip asset without an extractor fails with code zip', () async {
      final zipBytes = Uint8List.fromList(utf8.encode('PK fake zip'));
      final hash = sha256.convert(zipBytes).toString();
      final spec = toolSpec(ToolName.deno, Platform.darwin, Arch.arm64);
      final f = fakeFetch({'deno-aarch64-apple-darwin.zip.sha256sum': '$hash  deno-aarch64-apple-darwin.zip\n', 'deno-aarch64-apple-darwin.zip': zipBytes}, 'v2.9.7');
      await expectLater(
        installLatest(spec, Platform.darwin, dir.path, fetch: f),
        throwsA(isA<ToolDownloadError>().having((e) => e.code, 'code', ToolDownloadErrorCode.zip)),
      );
    });

    test('unzips a real Deno-style zip with the real extractor', () async {
      // Build a small zip with a single "deno" entry (deflated) plus a decoy, like the release asset.
      final payload = utf8.encode('#!/bin/sh\necho deno ${'x' * 5000}\n');
      final archive = Archive()
        ..add(ArchiveFile.bytes('deno', payload))
        ..add(ArchiveFile.string('README.md', 'not the binary'));
      final zipBytes = Uint8List.fromList(ZipEncoder().encodeBytes(archive));
      final hash = sha256.convert(zipBytes).toString();
      final spec = toolSpec(ToolName.deno, Platform.darwin, Arch.arm64);
      final f = fakeFetch({'deno-aarch64-apple-darwin.zip.sha256sum': '$hash  deno-aarch64-apple-darwin.zip\n', 'deno-aarch64-apple-darwin.zip': zipBytes}, 'v2.9.7');
      final r = await installLatest(spec, Platform.darwin, dir.path, fetch: f, extractZipEntry: extractZipEntry);
      expect(r.path, p.join(dir.path, 'deno-v2.9.7'));
      expect(await File(r.path).readAsBytes(), payload);
      expect((await File(r.path).stat()).mode & 0x49, isNot(0));
      expect(await readdir(), ['deno-v2.9.7']);
    });

    test('extractZipEntry rejects a missing entry and a non-zip', () async {
      final zipPath = p.join(dir.path, 'a.zip');
      await File(zipPath).writeAsBytes(ZipEncoder().encodeBytes(Archive()..add(ArchiveFile.string('other', 'x'))));
      await expectLater(
        extractZipEntry(zipPath, 'deno', p.join(dir.path, 'out')),
        throwsA(isA<ToolDownloadError>().having((e) => e.code, 'code', ToolDownloadErrorCode.zip)),
      );
      final junk = p.join(dir.path, 'junk.zip');
      await File(junk).writeAsString('PK fake zip');
      await expectLater(
        extractZipEntry(junk, 'deno', p.join(dir.path, 'out2')),
        throwsA(isA<ToolDownloadError>().having((e) => e.code, 'code', ToolDownloadErrorCode.zip)),
      );
    });
  });
}
