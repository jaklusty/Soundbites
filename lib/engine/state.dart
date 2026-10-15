/// The state snapshot the engine pushes to the UI after every change. Plain data, no Flutter.
library;

import 'library.dart';

enum LibraryStatus { none, open, missing, empty, held, stale, error }

class LockOwnerInfo {
  LockOwnerInfo({required this.host, required this.user, required this.pid, required this.app, required this.started, required this.heartbeat});
  final String host, user, app, started, heartbeat;
  final int pid;
}

class LibraryState {
  LibraryState({required this.status, this.path, this.warnings = const [], this.owner, this.message});
  final LibraryStatus status;
  final String? path;
  final List<String> warnings;
  final LockOwnerInfo? owner;
  final String? message;
  static final none = LibraryState(status: LibraryStatus.none);
}

class DownloadProgress {
  DownloadProgress({required this.run, required this.done, required this.total, this.current, this.paused = false});
  final String run;
  final int done, total;
  final String? current;
  final bool paused;
}

class FeedStatus {
  FeedStatus({this.lastChecked, this.lastResult, this.runsWaiting = 0, this.archiveRuns = 0, this.downloading, this.queueLength = 0});
  final String? lastChecked, lastResult;
  final int runsWaiting, archiveRuns, queueLength;
  final DownloadProgress? downloading;
  FeedStatus copyWith({String? lastChecked, String? lastResult, int? runsWaiting, int? archiveRuns, DownloadProgress? downloading, bool clearDownloading = false, int? queueLength}) => FeedStatus(
        lastChecked: lastChecked ?? this.lastChecked,
        lastResult: lastResult ?? this.lastResult,
        runsWaiting: runsWaiting ?? this.runsWaiting,
        archiveRuns: archiveRuns ?? this.archiveRuns,
        downloading: clearDownloading ? null : (downloading ?? this.downloading),
        queueLength: queueLength ?? this.queueLength,
      );
}

class ToolsStatus {
  ToolsStatus({this.ytdlp, this.deno, this.ffmpeg, this.message});
  final String? ytdlp, deno, ffmpeg, message;
}

class HealthIssue {
  HealthIssue({required this.at, required this.kind, required this.message, this.detail = ''});
  final String at, kind, message, detail;
}

class UpdateInfo {
  UpdateInfo({required this.version, required this.url});
  final String version, url;
}

class AppState {
  AppState({
    required this.version,
    required this.library,
    this.tracks = const [],
    this.lastRun,
    this.favourites = const {},
    this.promoteQueue = const [],
    this.promoting,
    Json? profile,
    this.activeView = '',
    this.issues = const [],
    this.pending = const [],
    this.lastRunSummary,
    this.reclaimableCount = 0,
    this.reclaimableBytes = 0,
    FeedStatus? feed,
    ToolsStatus? tools,
    this.update,
    this.libraryPath,
    this.feedBase = '',
    this.concurrency = 1,
    this.requestPauseMs = 2000,
  })  : profile = profile ?? <String, dynamic>{},
        feed = feed ?? FeedStatus(),
        tools = tools ?? ToolsStatus();

  final String version;
  final LibraryState library;
  final List<Track> tracks;
  final String? lastRun;
  final Set<String> favourites;
  final List<String> promoteQueue;
  final String? promoting;
  final Json profile;
  final String activeView;
  final List<HealthIssue> issues;
  final List<String> pending;
  final Json? lastRunSummary;
  final int reclaimableCount, reclaimableBytes;
  final FeedStatus feed;
  final ToolsStatus tools;
  final UpdateInfo? update;
  final String? libraryPath;
  final String feedBase;
  final int concurrency;
  final int requestPauseMs;

  Map<String, dynamic> get savedViews => ((profile['views'] as Map?)?['saved'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
}
