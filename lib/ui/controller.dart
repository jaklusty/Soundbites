/// What the UI may ask the engine to do. The real implementation wraps the engine; tests and
/// design previews use a fake fed with a library snapshot.
library;

import 'package:flutter/foundation.dart';

import '../engine/state.dart';

abstract class SoundbitesController {
  ValueListenable<AppState> get state;

  Future<void> chooseLibraryFolder();
  Future<void> createLibraryHere(String path);
  Future<void> reopenLibrary();
  Future<void> takeOverLock();

  Future<void> star(String id, bool on);
  Future<({int removed, int freed})> reclaim();
  Future<void> setActiveView(String key);
  Future<void> saveViewRule(String key, Map<String, dynamic> rule);
  Future<void> updateSettings({String? feedBase, int? concurrency, int? requestPauseMs});

  Future<void> openExternal(String url);
  Future<void> showInFolder(String kind, String id);
  /// Absolute path of a clip or full track for playback and drag-out, or null.
  String? mediaPath(String kind, String id);

  Future<void> retryTrack(String id);
  Future<void> wrongTrack(String id, bool alsoRemoveFull);
  Future<void> setTrackLink(String id, String url);
  Future<void> checkFeedNow();
  Future<void> pauseDownloads(bool paused);
  Future<void> cancelDownloads();
  Future<void> clearIssue(int index);
}
