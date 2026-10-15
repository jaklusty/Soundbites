/// "A newer version is available": GitHub Releases of the app's own repository, once a day.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

const String releasesApi = 'https://api.github.com/repos/jaklusty/soundbites/releases/latest';
const String releasesPage = 'https://github.com/jaklusty/soundbites/releases/latest';

int compareVersions(String a, String b) {
  List<int> parts(String s) => s.replaceFirst(RegExp(r'^v'), '').split(RegExp(r'[.-]')).map((x) => int.tryParse(x.trim()) ?? 0).toList();
  final pa = parts(a), pb = parts(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final d = (i < pa.length ? pa[i] : 0) - (i < pb.length ? pb[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

/// GET `url` and return the decoded JSON body, or null when the response is not 2xx. May throw
/// on network trouble; [checkForNewerRelease] swallows that.
typedef FetchJson = Future<Object?> Function(String url, Map<String, String> headers);

Future<Object?> defaultFetchJson(String url, Map<String, String> headers) async {
  final res = await http.get(Uri.parse(url), headers: headers).timeout(const Duration(seconds: 15));
  if (res.statusCode < 200 || res.statusCode >= 300) return null;
  return jsonDecode(res.body);
}

class NewerRelease {
  const NewerRelease({required this.version, required this.url});

  /// The tag without its leading "v".
  final String version;

  /// The release page to open.
  final String url;

  @override
  bool operator ==(Object other) => other is NewerRelease && other.version == version && other.url == url;

  @override
  int get hashCode => Object.hash(version, url);

  @override
  String toString() => 'NewerRelease($version, $url)';
}

Future<NewerRelease?> checkForNewerRelease(String currentVersion, {FetchJson fetchJson = defaultFetchJson}) async {
  try {
    final data = await fetchJson(releasesApi, {'Accept': 'application/vnd.github+json', 'User-Agent': 'Soundbites/$currentVersion'});
    if (data is! Map) return null;
    final tag = data['tag_name'];
    if (tag is! String || tag.isEmpty || data['draft'] == true || data['prerelease'] == true) return null;
    // Only app releases count; ffmpeg-* releases live in the same repository.
    if (!RegExp(r'^v?\d+\.\d+').hasMatch(tag)) return null;
    if (compareVersions(tag, currentVersion) > 0) {
      final html = data['html_url'];
      return NewerRelease(version: tag.replaceFirst(RegExp(r'^v'), ''), url: html is String ? html : releasesPage);
    }
    return null;
  } catch (_) {
    return null;
  }
}
