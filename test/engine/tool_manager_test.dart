// ToolManager: first-run install, weekly check keeping the current build on failure, pruning, missing files.
import 'dart:convert';
import 'dart:io' hide Platform;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:soundbites/engine/tool_manager.dart';
import 'package:soundbites/engine/tools.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sb-tm-');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });

  /// A GitHub stand-in serving yt-dlp (plain binary) and Deno (zip) at the given tags; `calls` records every URL.
  FetchLike fake({required String ytTag, required String denoTag, List<Uint8List>? denoZip, List<String>? calls, bool denoDown = false}) {
    final yt = Uint8List.fromList(utf8.encode('yt-dlp $ytTag'));
    final ytHash = sha256.convert(yt).toString();
    final zip = denoZip?.first ?? Uint8List.fromList(utf8.encode('zip $denoTag'));
    final zipHash = sha256.convert(zip).toString();
    final files = <String, Uint8List>{
      'SHA2-256SUMS': Uint8List.fromList(utf8.encode('$ytHash  yt-dlp_macos\n')),
      'yt-dlp_macos': yt,
      if (!denoDown) 'deno-aarch64-apple-darwin.zip.sha256sum': Uint8List.fromList(utf8.encode('$zipHash  deno-aarch64-apple-darwin.zip\n')),
      if (!denoDown) 'deno-aarch64-apple-darwin.zip': zip,
    };
    return (url) async {
      calls?.add(url);
      final name = url.split('/').last;
      final tag = url.contains('/yt-dlp/') ? ytTag : denoTag;
      final resolved = url.replaceFirst('/releases/latest/download/', '/releases/download/$tag/');
      final body = files[name];
      if (body == null) return FetchResponse(ok: false, status: 404, url: resolved, text: () async => '', body: null);
      return FetchResponse(ok: true, status: 200, url: resolved, text: () async => utf8.decode(body), body: Stream.value(body));
    };
  }

  Future<List<String>> readdir() async => (await dir.list().map((e) => p.basename(e.path)).toList())..sort();

  test('first run installs both tools; a second ensure without checkForNewer touches no network', () async {
    final log = <String>[];
    final calls = <String>[];
    final tm = ToolManager(toolsDir: p.join(dir.path, 'tools'), platform: Platform.darwin, arch: Arch.arm64, fetch: fake(ytTag: '2026.08.19', denoTag: 'v2.9.7', calls: calls), log: log.add);
    expect((await tm.installed()).ytdlp, isNull);
    final paths = await tm.ensure(false);
    expect(paths.ytdlp, p.join(dir.path, 'tools', 'yt-dlp-2026.08.19'));
    expect(paths.deno, isNull); // the fake zip is not a real zip: Deno fails, yt-dlp still usable
    expect(tm.lastMessage, contains('deno could not be downloaded'));
    expect(tm.lastMessage, contains('it will be tried again'));
    expect(log, contains('yt-dlp 2026.08.19 installed'));
    expect(tm.versions(paths), (ytdlp: '2026.08.19', deno: null));
    expect(tm.versions(ToolPaths(ytdlp: r'C:\x\yt-dlp-2026.08.19.exe', deno: '/t/deno-v2.9.7')), (ytdlp: '2026.08.19', deno: 'v2.9.7'));

    calls.clear();
    final again = await tm.ensure(false);
    expect(again.ytdlp, paths.ytdlp);
    // yt-dlp is present so it is skipped; Deno is still missing and tried again.
    expect(calls.where((u) => u.contains('/yt-dlp/')), isEmpty);
    expect(calls.where((u) => u.contains('/denoland/')), isNotEmpty);
  });

  test('checkForNewer installs the newer build and prunes the old one; a failed check keeps the current build', () async {
    final toolsDir = p.join(dir.path, 'tools');
    final log = <String>[];
    var tm = ToolManager(toolsDir: toolsDir, platform: Platform.darwin, arch: Arch.arm64, fetch: fake(ytTag: '2026.07.01', denoTag: 'v2.9.7', denoDown: true), log: log.add);
    await tm.ensure(false);
    await File(p.join(toolsDir, 'yt-dlp-2026.06.01')).writeAsString('old');
    await File(p.join(toolsDir, 'stray.part')).writeAsString('partial');

    tm = ToolManager(toolsDir: toolsDir, platform: Platform.darwin, arch: Arch.arm64, fetch: fake(ytTag: '2026.08.19', denoTag: 'v2.9.7', denoDown: true), log: log.add);
    final paths = await tm.ensure(true);
    expect(paths.ytdlp, p.join(toolsDir, 'yt-dlp-2026.08.19'));
    expect(await Directory(toolsDir).list().map((e) => p.basename(e.path)).toList()..sort(), ['stray.part', 'yt-dlp-2026.08.19']);
    expect(tm.lastMessage, contains('deno could not be downloaded'));

    // Network gone: the update check fails but the current build stays and nothing is reported for it.
    tm = ToolManager(toolsDir: toolsDir, platform: Platform.darwin, arch: Arch.arm64, fetch: (url) async => throw const SocketException('offline'), log: log.add);
    final kept = await tm.ensure(true);
    expect(kept.ytdlp, p.join(toolsDir, 'yt-dlp-2026.08.19'));
    expect(log.last, startsWith('yt-dlp: update check failed'));
    expect(tm.lastMessage, contains('deno could not be downloaded'));
    expect(tm.lastMessage, isNot(contains('yt-dlp could not')));
  });

  test('ensure shares one in-flight run and verifyPresent reports a vanished file', () async {
    final calls = <String>[];
    final tm = ToolManager(toolsDir: dir.path, platform: Platform.darwin, arch: Arch.arm64, fetch: fake(ytTag: '2026.08.19', denoTag: 'v2.9.7', calls: calls));
    final a = tm.ensure(false);
    final b = tm.ensure(false);
    expect(identical(a, b), isTrue);
    final paths = await a;
    expect(calls.where((u) => u.endsWith('SHA2-256SUMS')).length, 1);
    expect(await tm.verifyPresent(paths), isNull);
    await File(paths.ytdlp!).delete();
    expect(await tm.verifyPresent(paths), startsWith('yt-dlp has gone missing from ${dir.path}'));
    expect(await tm.verifyPresent(ToolPaths()), isNull);
    expect(await readdir(), isNot(contains('yt-dlp-2026.08.19')));
  });
}
