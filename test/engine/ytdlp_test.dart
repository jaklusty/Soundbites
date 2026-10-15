// Port of the "yt-dlp wrapper" cases of electron/test/feed.test.ts.
import 'package:flutter_test/flutter_test.dart';
import 'package:soundbites/engine/ytdlp.dart';

void main() {
  group('yt-dlp wrapper', () {
    test('builds safe arguments', () {
      final args = baseArgs(const YtDlpOptions(paths: YtDlpPaths(ytdlp: 'y', deno: '/d/deno', ffmpeg: '/f/ffmpeg'), sleepRequests: 2));
      expect(args, contains('--no-remote-components'));
      expect(args.join(' '), contains('--js-runtimes deno:/d/deno'));
      expect(args.join(' '), contains('--ffmpeg-location /f/ffmpeg'));
      expect(args.join(' '), contains('--sleep-requests 2'));
      expect(args, isNot(contains('--cookies-from-browser')));
      expect(cleanQuery('a\x00b\x1fc  '), 'a b c');
    });
    test('leaves out Deno and sleep when not configured', () {
      final args = baseArgs(const YtDlpOptions(paths: YtDlpPaths(ytdlp: 'y', ffmpeg: '/f/ffmpeg'), sleepRequests: 0));
      expect(args, isNot(contains('--js-runtimes')));
      expect(args, isNot(contains('--sleep-requests')));
      expect(args, contains('--no-playlist'));
    });
    test('caps a query at 200 characters', () {
      expect(cleanQuery('x' * 300).length, 200);
      expect(cleanQuery('  \t\n  '), '');
    });
    test('parses print lines and ignores junk', () {
      final r = parsePrintLines('u5Ee8QrWyhc\tBicep - Glue\tBicep\t237\nnotanid\tx\ty\tz\nabcdefghijk\tT\tNA\tNA\n');
      expect(r, [
        const ResolvedUpload(videoId: 'u5Ee8QrWyhc', url: 'https://www.youtube.com/watch?v=u5Ee8QrWyhc', title: 'Bicep - Glue', channel: 'Bicep', duration: 237),
        const ResolvedUpload(videoId: 'abcdefghijk', url: 'https://www.youtube.com/watch?v=abcdefghijk', title: 'T', channel: '', duration: null),
      ]);
      expect(extractorFailure.hasMatch('ERROR: [youtube] abc: Unable to extract player version'), isTrue);
      expect(extractorFailure.hasMatch('ERROR: Video unavailable'), isFalse);
    });
    test('handles CRLF, short lines and zero durations', () {
      final r = parsePrintLines('u5Ee8QrWyhc\r\nabcdefghijk\tT\tC\t0\r\n');
      expect(r.length, 2);
      expect(r[0].title, '');
      expect(r[0].channel, '');
      expect(r[0].duration, isNull);
      expect(r[1].duration, isNull);
    });
    test('extractor-failure regex is case-insensitive and covers the js runtime', () {
      expect(extractorFailure.hasMatch('error: no js runtime available'), isTrue);
      expect(extractorFailure.hasMatch('HTTP Error 403: Forbidden'), isTrue);
      expect(extractorFailure.hasMatch('HTTP Error 404: Not Found'), isFalse);
    });
    test('version reads the first word of stdout, null when the tool does not run', () async {
      expect(await version('/bin/echo'), isNotNull);
      expect(await version('/nonexistent/yt-dlp'), isNull);
    });
  });
}
