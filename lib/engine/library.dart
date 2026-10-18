/// Shared models and helpers for the library files (library.json version 1).
///
/// Records are kept as plain JSON maps wrapped in thin classes, so that fields the app does
/// not know about survive a round trip untouched and key order is preserved. The existing
/// library must open and be written back unchanged apart from what the app actually edits.
library;

import 'dart:convert';

typedef Json = Map<String, dynamic>;

/// A track row in library.json. Wraps the map; getters/setters cover the known fields.
class Track {
  Track(this.json);

  /// Create a brand-new row the way ingest.py did (same key order).
  factory Track.create({required String id, required String firstSeen}) => Track(<String, dynamic>{
        'id': id,
        'first_seen': firstSeen,
        'runs': <String>[],
        'clip': null,
        'clip_present': false,
      });

  final Json json;

  String get id => json['id'] as String? ?? '';
  String? get title => _str('title');
  String? get artist => _str('artist');
  String? get platform => _str('platform');
  String? get direction => _str('direction');
  String? get energy => _str('energy');
  String? get suits => _str('suits');
  String? get licence => _str('licence');
  String? get notes => _str('notes');
  String? get sourceUrl => _str('source_url');
  String? get userSourceUrl => _str('user_source_url');
  String? get lastSeen => _str('last_seen');
  String? get firstSeen => _str('first_seen');
  String? get clip => _str('clip');
  String? get full => _str('full');
  String? get fullFormat => _str('full_format');
  String? get fullError => _str('full_error');
  String? get hookMethod => _str('hook_method');
  String? get hookDetail => _str('hook_detail');
  String? get matchStatus => _str('match_status');
  bool get clipPresent => json['clip_present'] == true;
  bool get pinned => json['pinned'] == true;
  int? get uses => _int('uses');
  int? get bpm => _int('bpm');
  int? get clipBytes => _int('clip_bytes');
  int? get fullBytes => _int('full_bytes');
  double? get hookAt => (json['hook_at'] as num?)?.toDouble();
  List<String> get runs => (json['runs'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
  List<String> get mood => (json['mood'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
  List<String> get profiles => (json['profiles'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
  List<String> get rejectedVideoIds =>
      (json['rejected_video_ids'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
  Map<String, num> get usesHistory =>
      ((json['uses_history'] as Map?) ?? const {}).map((k, v) => MapEntry(k.toString(), (v as num?) ?? 0));
  Json? get match => (json['match'] as Map?)?.cast<String, dynamic>();

  String? _str(String k) {
    final v = json[k];
    return v?.toString();
  }

  int? _int(String k) {
    final v = json[k];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return null;
  }

  void set(String key, Object? value) => json[key] = value;
  void remove(String key) => json.remove(key);

  String get label => artist != null && artist!.isNotEmpty ? '$title — $artist' : (title ?? id);
}

/// library.json as a whole.
class Library {
  Library(this.json) {
    json.putIfAbsent('version', () => 1);
    json.putIfAbsent('tracks', () => <dynamic>[]);
  }

  factory Library.empty() => Library(<String, dynamic>{'version': 1, 'tracks': <dynamic>[]});

  final Json json;

  int get version => (json['version'] as num?)?.toInt() ?? 1;
  List<dynamic> get _rawTracks => json['tracks'] as List<dynamic>;
  List<Track> get tracks => _rawTracks.map((e) => Track((e as Map).cast<String, dynamic>())).toList();
  String? get lastRun => json['last_run'] as String?;
  set lastRun(String? v) => json['last_run'] = v;
  String? get updated => json['updated'] as String?;
  set updated(String? v) => json['updated'] = v;

  Track? find(String id) {
    for (final raw in _rawTracks) {
      final m = (raw as Map).cast<String, dynamic>();
      if (m['id'] == id) return Track(m);
    }
    return null;
  }

  Track add(Track t) {
    _rawTracks.add(t.json);
    return t;
  }

  Set<String> get ids => _rawTracks.map((e) => ((e as Map)['id'] ?? '').toString()).toSet();
}

/// favourites.json
class Favourites {
  Favourites(this.json);
  factory Favourites.empty() => Favourites(<String, dynamic>{'ids': <String>[]});
  final Json json;
  List<String> get ids => (json['ids'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
  set ids(List<String> v) => json['ids'] = v;
  Map<String, dynamic> get starredAt => ((json['starred_at'] as Map?) ?? <String, dynamic>{}).cast<String, dynamic>();
}

/// A candidate after normalisation (hard requirement 3): mood is a list, suits is one string.
class Candidate {
  Candidate({required this.title, required this.artist});

  final String title;
  final String artist;
  String? search;
  String? sourceUrl;
  String? local;
  Object? hookStart; // String like "0:30" or a number of seconds
  String? platform;
  String? direction;
  int? uses;
  int? bpm;
  String? energy;
  List<String>? mood;
  String? suits;
  List<String>? profiles;
  String? licence;
  String? notes;
  bool pin = false;

  /// The fields ingest.merge copies onto a track, in the Python's order.
  Map<String, Object?> get trackFields => <String, Object?>{
        'title': title,
        'artist': artist,
        'platform': platform,
        'direction': direction,
        'uses': uses,
        'bpm': bpm,
        'energy': energy,
        'mood': mood,
        'suits': suits,
        'profiles': profiles,
        'licence': licence,
        'notes': notes,
        'source_url': sourceUrl,
      };

  String get label => artist.isNotEmpty ? '$title — $artist' : title;
}

/// Where a candidate came from decides which local-only fields are honoured.
enum CandidateSource { feed, pending }

class Rejected {
  Rejected(this.reason);
  final String reason;
}

/// Python's json.dumps(indent=2, ensure_ascii=False) layout: 2-space indent, non-ASCII kept.
/// Dart's JsonEncoder.withIndent already matches it ("key": value, items on their own lines).
final JsonEncoder prettyJson = const JsonEncoder.withIndent('  ');

String encodeJson(Object? data) => '${prettyJson.convert(data)}\n';

/// YYYY-MM-DD and a real calendar date. (libstore.valid_run_stamp)
bool validRunStamp(Object? value) {
  if (value is! String) return false;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (m == null) return false;
  final y = int.parse(m.group(1)!), mo = int.parse(m.group(2)!), d = int.parse(m.group(3)!);
  final date = DateTime.utc(y, mo, d);
  return date.year == y && date.month == mo && date.day == d;
}

/// Later of two stamps; keeps last_run monotonic. (libstore.newer_stamp)
String? newerStamp(Object? a, Object? b) {
  if (!validRunStamp(a)) return validRunStamp(b) ? b as String : null;
  if (!validRunStamp(b)) return a as String;
  return (a as String).compareTo(b as String) >= 0 ? a : b;
}

/// "0:20" / "1:05.9" / 95 → whole seconds. (ingest.parse_ts)
int parseTs(Object? value) {
  if (value == null) return 20;
  if (value is num) return value.toInt().clamp(0, 1 << 31);
  final parts = value.toString().trim().split(':');
  double seconds = 0;
  for (final p in parts) {
    final n = double.tryParse(p);
    if (n == null) return 20;
    seconds = seconds * 60 + n;
  }
  return seconds < 0 ? 0 : seconds.truncate();
}

/// http(s) only, and never something that could be read as an option. (libstore.safe_media_url)
String? safeMediaUrl(Object? url) {
  final s = (url ?? '').toString().trim();
  if (s.isEmpty || s.startsWith('-')) return null;
  return RegExp(r'^https?://', caseSensitive: false).hasMatch(s) ? s : null;
}

/// Hard requirement 6: a feed source_url is accepted only for youtube.com and youtu.be.
String? youtubeUrlOnly(Object? url) {
  final s = safeMediaUrl(url);
  if (s == null) return null;
  final u = Uri.tryParse(s);
  if (u == null) return null;
  final host = u.host.toLowerCase();
  final ok = host == 'youtu.be' || host == 'youtube.com' || host.endsWith('.youtube.com');
  return ok ? s : null;
}

final RegExp ytId = RegExp(r'^[A-Za-z0-9_-]{11}$');

/// The 11-character video id from a youtube.com or youtu.be link.
String? youtubeVideoId(String url) {
  final u = Uri.tryParse(url);
  if (u == null) return null;
  final host = u.host.toLowerCase();
  String? id;
  if (host == 'youtu.be') {
    id = u.pathSegments.isNotEmpty ? u.pathSegments.first : null;
  } else if (host == 'youtube.com' || host.endsWith('.youtube.com')) {
    id = u.queryParameters['v'];
    if (id == null) {
      final m = RegExp(r'^/(?:shorts|embed|live)/([A-Za-z0-9_-]{11})').firstMatch(u.path);
      id = m?.group(1);
    }
  }
  return id != null && ytId.hasMatch(id) ? id : null;
}

String? _asString(Object? v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num && v.isFinite) return v.truncate();
  if (v is String && RegExp(r'^\s*\d+\s*$').hasMatch(v)) return int.parse(v.trim());
  return null;
}

/// Normalise a raw candidate map. Feed candidates lose the local-only fields the brief lists
/// (`local`, `pin`, `profiles`, `hook_start`) and may only carry a YouTube `source_url`; a run
/// file the user dropped into pending/ keeps them.
Object normalizeCandidate(Map raw, CandidateSource source) {
  final title = _asString(raw['title']);
  final artist = _asString(raw['artist']) ?? '';
  if (title == null) return Rejected('(candidate with no title)');
  final c = Candidate(title: title, artist: artist);
  c.search = _asString(raw['search']);
  c.sourceUrl = source == CandidateSource.feed ? youtubeUrlOnly(raw['source_url']) : safeMediaUrl(raw['source_url']);
  c.platform = _asString(raw['platform']);
  c.direction = _asString(raw['direction']);
  c.energy = _asString(raw['energy']);
  c.licence = _asString(raw['licence']);
  c.notes = _asString(raw['notes']);
  c.uses = _asInt(raw['uses']);
  c.bpm = _asInt(raw['bpm']);

  final mood = raw['mood'];
  if (mood is List) {
    final m = mood.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
    if (m.isNotEmpty) c.mood = m;
  } else if (mood is String && mood.trim().isNotEmpty) {
    c.mood = mood.split(RegExp(r'[,;]')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  }
  final suits = raw['suits'];
  if (suits is List) {
    final s = suits.map((e) => e.toString().trim()).where((x) => x.isNotEmpty).join(' ');
    if (s.isNotEmpty) c.suits = s;
  } else {
    c.suits = _asString(suits);
  }

  if (source == CandidateSource.pending) {
    c.local = _asString(raw['local']);
    final hs = raw['hook_start'];
    if (hs != null && hs.toString().trim().isNotEmpty) c.hookStart = hs is num ? hs : hs.toString();
    final profiles = raw['profiles'];
    if (profiles is List) {
      final p = profiles.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
      if (p.isNotEmpty) c.profiles = p;
    }
    if (raw['pin'] == true || (raw['pin'] is num && raw['pin'] != 0)) c.pin = true;
  }
  return c;
}

/// ISO timestamp the way Python wrote it: seconds precision, +00:00 suffix.
String nowIso([DateTime? at]) {
  final d = (at ?? DateTime.now()).toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}T${two(d.hour)}:${two(d.minute)}:${two(d.second)}+00:00';
}

/// Tracks from the newest `keepRuns` runs that have no clip but could get one: the ones a
/// "try again for all" should queue. Older runs are metadata only by design.
List<Track> retryableTracks(Library lib, int keepRuns) {
  final runs = lib.tracks.expand((t) => t.runs).where(validRunStamp).toSet().toList()..sort();
  final recent = runs.reversed.take(keepRuns).toSet();
  return lib.tracks.where((t) {
    if (t.clipPresent || t.json['local'] != null || !t.runs.any(recent.contains)) return false;
    return t.userSourceUrl != null || t.sourceUrl != null || ((t.artist ?? '').isNotEmpty && (t.title ?? '').isNotEmpty);
  }).toList();
}
