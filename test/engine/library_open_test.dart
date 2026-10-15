import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:soundbites/engine/library_open.dart';
import 'package:soundbites/engine/settings.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sb-open-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  group('opening a library', () {
    test('missing folder → missing, never creates anything', () async {
      expect(await probeLibrary(p.join(root.path, 'gone')), isA<ProbeMissing>());
      expect(await root.list().toList(), isEmpty);
    });

    test('empty folder → empty; createLibrary writes the three files and a neutral profile', () async {
      final lib = p.join(root.path, 'lib');
      await Directory(lib).create();
      expect((await probeLibrary(lib)).status, 'empty');
      await createLibrary(lib);
      expect((await probeLibrary(lib)).status, 'ok');
      expect(jsonDecode(await File(p.join(lib, 'library.json')).readAsString()), {'version': 1, 'tracks': []});
      expect(jsonDecode(await File(p.join(lib, 'favourites.json')).readAsString()), {'ids': []});
      final profileText = await File(p.join(lib, 'profile.json')).readAsString();
      final profile = jsonDecode(profileText) as Map<String, dynamic>;
      expect(profile['retention']['keep_runs'], 8);
      expect(profile['promote']['format'], 'wav16');
      expect((profile['views']['saved'] as Map).keys.toList(), ['instrumental', 'high-energy', 'low-energy']);
      expect(profileText, isNot(matches(RegExp(r'jak', caseSensitive: false))));
      await expectLater(
        createLibrary(lib),
        throwsA(isA<StateError>().having((e) => e.message, 'message', matches(RegExp(r'already exists')))),
      );
    });

    test('a file is not a folder', () async {
      await File(p.join(root.path, 'f')).writeAsString('x');
      expect(await probeLibrary(p.join(root.path, 'f')), isA<ProbeNotAFolder>());
    });

    test('warns about synced and long paths', () {
      const home = '/Users/someone';
      expect(pathWarnings('/Users/someone/Movies/Soundbites', home: home, platform: 'macos'), isEmpty);
      expect(pathWarnings('/Users/someone/Documents/Soundbites', home: home, platform: 'macos')[0], contains('iCloud'));
      expect(
        pathWarnings('/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/x', home: home, platform: 'macos')[0],
        contains('iCloud'),
      );
      expect(pathWarnings('/Users/someone/OneDrive/x', home: home, platform: 'macos'), hasLength(1));
      expect(pathWarnings('/Users/someone/Desktop/${'a' * 120}', home: home, platform: 'macos'), hasLength(2));
      expect(defaultProfile()['views']['saved']['high-energy']['rule'], isNotNull);
    });

    test('Windows paths use the OneDrive wording and a backslash separator', () {
      const home = r'C:\Users\someone';
      expect(pathWarnings(r'C:\Users\someone\Videos\Soundbites', home: home, platform: 'windows'), isEmpty);
      expect(pathWarnings(r'C:\Users\someone\OneDrive\Soundbites', home: home, platform: 'windows')[0], contains('OneDrive'));
      expect(pathWarnings(r'C:\Users\someone\Documents\Soundbites', home: home, platform: 'windows'), isEmpty);
    });
  });

  group('settings', () {
    test('defaults, persists and sanitises', () async {
      final s = Settings(root.path);
      final first = await s.load();
      expect(first.feedBase, defaultFeedBase);
      expect(first.concurrency, 1);
      await s.update((c) => c.copyWith(concurrency: 9, feedBase: 'https://example.com/feed', libraryPath: '/x'));
      final again = await Settings(root.path).load();
      expect(again.concurrency, 3);
      expect(again.feedBase, 'https://example.com/feed/');
      expect(again.libraryPath, '/x');
    });

    test('feed base normalisation', () {
      expect(normaliseFeedBase(''), defaultFeedBase);
      expect(normaliseFeedBase('/tmp/feed'), '/tmp/feed');
      expect(sanitize(const AppSettings(feedBase: 'x', concurrency: 0, requestPauseMs: -5)).concurrency, 1);
      expect(sanitize(const AppSettings(feedBase: 'x', concurrency: 0, requestPauseMs: -5)).requestPauseMs, 0);
      expect(isHttpFeed('HTTPS://x/'), isTrue);
      expect(isHttpFeed('/tmp/feed'), isFalse);
    });

    test('a corrupt settings file with no backup starts from defaults', () async {
      await File(p.join(root.path, 'settings.json')).writeAsString('{{');
      final s = await Settings(root.path).load();
      expect(s.feedBase, defaultFeedBase);
      expect(s.concurrency, 1);
    });

    test('unknown or odd values in the file fall back to sane ones', () {
      final s = AppSettings.fromJson({
        'concurrency': '2',
        'requestPauseMs': -1,
        'libraryPath': 42,
        'window': {'width': 800.0, 'height': 600, 'maximized': true},
      });
      expect(s.concurrency, 2);
      expect(s.requestPauseMs, 0);
      expect(s.libraryPath, isNull);
      expect(s.window?.width, 800);
      expect(s.window?.maximized, isTrue);
      expect(s.toJson()['window'], {'width': 800, 'height': 600, 'maximized': true});
    });
  });
}
