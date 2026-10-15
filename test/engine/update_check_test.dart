// Port of the "release check" cases of electron/test/feed.test.ts.
import 'package:flutter_test/flutter_test.dart';
import 'package:soundbites/engine/update_check.dart';

void main() {
  group('release check', () {
    test('compares versions', () {
      expect(compareVersions('1.2.0', '1.10.0'), lessThan(0));
      expect(compareVersions('v0.2.0', '0.1.9'), greaterThan(0));
      expect(compareVersions('0.2.0', 'v0.2.0'), 0);
      expect(compareVersions('0.2', '0.2.0'), 0);
      expect(compareVersions('0.2.0-beta', '0.2.0'), 0);
    });
    test('reads the latest release', () async {
      Future<Object?> fake(String url, Map<String, String> headers) async {
        expect(url, releasesApi);
        expect(headers['Accept'], 'application/vnd.github+json');
        expect(headers['User-Agent'], startsWith('Soundbites/'));
        return {'tag_name': 'v0.2.0', 'html_url': 'https://x/r'};
      }

      expect(await checkForNewerRelease('0.1.0', fetchJson: fake), const NewerRelease(version: '0.2.0', url: 'https://x/r'));
      expect(await checkForNewerRelease('0.2.0', fetchJson: fake), isNull);
      Future<Object?> ff(String url, Map<String, String> headers) async => {'tag_name': 'ffmpeg-n8.1.3-3', 'html_url': 'x'};
      expect(await checkForNewerRelease('0.1.0', fetchJson: ff), isNull);
    });
    test('ignores drafts, prereleases, bad responses and network errors', () async {
      Future<Object?> draft(String url, Map<String, String> headers) async => {'tag_name': 'v9.0.0', 'draft': true};
      Future<Object?> pre(String url, Map<String, String> headers) async => {'tag_name': 'v9.0.0', 'prerelease': true};
      Future<Object?> notOk(String url, Map<String, String> headers) async => null;
      Future<Object?> noTag(String url, Map<String, String> headers) async => {'html_url': 'x'};
      Future<Object?> boom(String url, Map<String, String> headers) async => throw Exception('offline');
      Future<Object?> noUrl(String url, Map<String, String> headers) async => {'tag_name': '9.0.0'};
      expect(await checkForNewerRelease('0.1.0', fetchJson: draft), isNull);
      expect(await checkForNewerRelease('0.1.0', fetchJson: pre), isNull);
      expect(await checkForNewerRelease('0.1.0', fetchJson: notOk), isNull);
      expect(await checkForNewerRelease('0.1.0', fetchJson: noTag), isNull);
      expect(await checkForNewerRelease('0.1.0', fetchJson: boom), isNull);
      expect(await checkForNewerRelease('0.1.0', fetchJson: noUrl), const NewerRelease(version: '9.0.0', url: releasesPage));
    });
  });
}
