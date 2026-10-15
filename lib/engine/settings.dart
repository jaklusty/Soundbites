/// App settings live in the OS app-data folder (not in the library), so the library folder stays
/// portable. Written with the same safe-write rules as the library files.
library;

import 'library.dart';
import 'store.dart';

const String defaultFeedBase = 'https://raw.githubusercontent.com/jaklusty/Audio-Trends/main/';

// ignore: constant_identifier_names
const String DEFAULT_FEED_BASE = defaultFeedBase;

const Object _unset = Object();

class WindowBounds {
  const WindowBounds({this.x, this.y, required this.width, required this.height, this.maximized});

  static WindowBounds? fromJson(Object? v) {
    if (v is! Map) return null;
    final width = v['width'], height = v['height'];
    if (width is! num || height is! num) return null;
    final x = v['x'], y = v['y'], maximized = v['maximized'];
    return WindowBounds(
      x: x is num ? x.toInt() : null,
      y: y is num ? y.toInt() : null,
      width: width.toInt(),
      height: height.toInt(),
      maximized: maximized is bool ? maximized : null,
    );
  }

  final int? x;
  final int? y;
  final int width;
  final int height;
  final bool? maximized;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (x != null) 'x': x,
        if (y != null) 'y': y,
        'width': width,
        'height': height,
        if (maximized != null) 'maximized': maximized,
      };
}

class AppSettings {
  const AppSettings({
    this.libraryPath,
    this.feedBase = defaultFeedBase,
    this.concurrency = 1,
    this.requestPauseMs = 2000,
    this.window,
    this.toolsCheckedAt,
    this.feedCheckedAt,
    this.updateCheckedAt,
  });

  /// `DEFAULT_SETTINGS` in the TypeScript.
  const AppSettings.defaults() : this();

  /// `{...DEFAULT_SETTINGS, ...data}`: every field the file lacks keeps its default. A
  /// `libraryPath` that is not a string is dropped (sanitize).
  factory AppSettings.fromJson(Json data) {
    const d = AppSettings.defaults();
    String? str(String k) => data[k] is String ? data[k] as String : null;
    return sanitize(AppSettings(
      libraryPath: str('libraryPath'),
      feedBase: data.containsKey('feedBase') ? normaliseFeedBase(data['feedBase']) : d.feedBase,
      concurrency: data.containsKey('concurrency') ? _num(data['concurrency'], 1) : d.concurrency,
      requestPauseMs: data.containsKey('requestPauseMs') ? _num(data['requestPauseMs'], 0) : d.requestPauseMs,
      window: WindowBounds.fromJson(data['window']),
      toolsCheckedAt: str('toolsCheckedAt'),
      feedCheckedAt: str('feedCheckedAt'),
      updateCheckedAt: str('updateCheckedAt'),
    ));
  }

  final String? libraryPath;

  /// Feed base: an https address ending in / or a local folder path.
  final String feedBase;

  /// Simultaneous downloads, 1..3.
  final int concurrency;

  /// Milliseconds between requests to YouTube.
  final int requestPauseMs;
  final WindowBounds? window;

  /// When tools were last checked for a newer release (ISO).
  final String? toolsCheckedAt;

  /// When the feed was last checked (ISO), for the status line.
  final String? feedCheckedAt;

  /// When the app last looked for a newer release (ISO).
  final String? updateCheckedAt;

  /// `Math.trunc(Number(v) || fallback)`: a number is truncated, a numeric string parsed,
  /// anything else (or 0/NaN) becomes `fallback`.
  static int _num(Object? v, int fallback) {
    num? n;
    if (v is num) {
      n = v;
    } else if (v is String) {
      n = num.tryParse(v.trim());
    } else if (v is bool) {
      n = v ? 1 : 0;
    }
    if (n == null || n.isNaN || n == 0) return fallback;
    return n.truncate();
  }

  /// Optional fields can be cleared by passing `null` explicitly.
  AppSettings copyWith({
    Object? libraryPath = _unset,
    String? feedBase,
    int? concurrency,
    int? requestPauseMs,
    Object? window = _unset,
    Object? toolsCheckedAt = _unset,
    Object? feedCheckedAt = _unset,
    Object? updateCheckedAt = _unset,
  }) =>
      AppSettings(
        libraryPath: identical(libraryPath, _unset) ? this.libraryPath : libraryPath as String?,
        feedBase: feedBase ?? this.feedBase,
        concurrency: concurrency ?? this.concurrency,
        requestPauseMs: requestPauseMs ?? this.requestPauseMs,
        window: identical(window, _unset) ? this.window : window as WindowBounds?,
        toolsCheckedAt: identical(toolsCheckedAt, _unset) ? this.toolsCheckedAt : toolsCheckedAt as String?,
        feedCheckedAt: identical(feedCheckedAt, _unset) ? this.feedCheckedAt : feedCheckedAt as String?,
        updateCheckedAt: identical(updateCheckedAt, _unset) ? this.updateCheckedAt : updateCheckedAt as String?,
      );

  Json toJson() => <String, dynamic>{
        if (libraryPath != null) 'libraryPath': libraryPath,
        'feedBase': feedBase,
        'concurrency': concurrency,
        'requestPauseMs': requestPauseMs,
        if (window != null) 'window': window!.toJson(),
        if (toolsCheckedAt != null) 'toolsCheckedAt': toolsCheckedAt,
        if (feedCheckedAt != null) 'feedCheckedAt': feedCheckedAt,
        if (updateCheckedAt != null) 'updateCheckedAt': updateCheckedAt,
      };
}

class Settings {
  Settings(String appDataDir) : _store = Store(appDataDir);

  final Store _store;
  AppSettings? _cache;

  Future<AppSettings> load() async {
    Json? data;
    try {
      data = (await _store.read('settings.json')).data;
    } on StoreError {
      data = null; // a corrupt settings file with no backup: start from defaults, nothing precious here
    }
    _cache = data == null ? sanitize(const AppSettings.defaults()) : AppSettings.fromJson(data);
    return _cache!;
  }

  AppSettings get current => _cache ?? const AppSettings.defaults();

  /// `patch` receives the current settings and returns the new ones (use `copyWith`).
  Future<AppSettings> update(AppSettings Function(AppSettings current) patch) async {
    final next = sanitize(patch(current));
    await _store.write('settings.json', next.toJson());
    _cache = next;
    return next;
  }
}

AppSettings sanitize(AppSettings s) => s.copyWith(
      concurrency: (s.concurrency == 0 ? 1 : s.concurrency).clamp(1, 3),
      requestPauseMs: s.requestPauseMs < 0 ? 0 : s.requestPauseMs,
      feedBase: normaliseFeedBase(s.feedBase),
    );

/// An https URL gets a trailing slash; anything else is treated as a local folder path.
String normaliseFeedBase(Object? value) {
  final s = (value ?? '').toString().trim();
  if (s.isEmpty) return defaultFeedBase;
  if (isHttpFeed(s)) return s.endsWith('/') ? s : '$s/';
  return s;
}

bool isHttpFeed(String base) => RegExp(r'^https?://', caseSensitive: false).hasMatch(base);
