/// One audio player for the whole window: the bottom bar shows what is playing with a scrubber.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../../engine/library.dart';

class NowPlaying {
  NowPlaying(this.track, this.path, this.kind);
  final Track track;
  final String path;
  final String kind; // 'clip' | 'full'
}

class PlayerModel extends ChangeNotifier {
  PlayerModel() {
    _sub = _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        _player.pause();
        _player.seek(Duration.zero);
      }
      notifyListeners();
    });
    _pos = _player.positionStream.listen((_) => notifyListeners());
  }

  final AudioPlayer _player = AudioPlayer();
  late final StreamSubscription<PlayerState> _sub;
  late final StreamSubscription<Duration> _pos;
  NowPlaying? current;
  String? error;

  bool get playing => _player.playing;
  Duration get position => _player.position;
  Duration? get duration => _player.duration;

  Future<void> play(Track track, String path, String kind) async {
    error = null;
    if (current?.path == path) {
      if (_player.playing) {
        await _player.pause();
      } else {
        await _player.play();
      }
      notifyListeners();
      return;
    }
    try {
      current = NowPlaying(track, path, kind);
      notifyListeners();
      if (!File(path).existsSync()) throw const FileSystemException('missing');
      await _player.setFilePath(path);
      unawaited(_player.play());
    } catch (e) {
      error = 'That clip would not play. The file may have been removed; "Get clip again" fetches it.';
      current = null;
      notifyListeners();
    }
  }

  Future<void> toggle() async {
    if (current == null) return;
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
    notifyListeners();
  }

  Future<void> seek(Duration d) => _player.seek(d);

  Future<void> stop() async {
    await _player.stop();
    current = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub.cancel();
    _pos.cancel();
    _player.dispose();
    super.dispose();
  }
}
