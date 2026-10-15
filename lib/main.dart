import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'engine/engine.dart';
import 'engine/instance_lock.dart';
import 'ui/app.dart';
import 'ui/controller.dart';
import 'ui/demo_controller.dart';
import 'ui/engine_controller.dart';
import 'version.dart';

/// The bundled ffmpeg: Contents/Resources/ffmpeg on macOS, ffmpeg/ next to the exe on Windows,
/// `vendor/ffmpeg/<os>/` in development, PATH as a last resort (Linux development only).
String ffmpegPath() {
  final exe = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
  final exeDir = p.dirname(Platform.resolvedExecutable);
  final candidates = <String>[
    if (Platform.isMacOS) p.join(exeDir, '..', 'Resources', 'ffmpeg', exe),
    if (Platform.isWindows) p.join(exeDir, 'ffmpeg', exe),
    p.join(Directory.current.path, 'vendor', 'ffmpeg', Platform.isWindows ? 'win' : 'mac', exe),
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return p.normalize(c);
  }
  return exe;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows || Platform.isLinux) {
    try {
      JustAudioMediaKit.ensureInitialized();
    } catch (_) {
      // No libmpv on this machine (headless CI): the UI still runs, playback reports an error.
    }
  }
  try {
    await windowManager.ensureInitialized();
    await windowManager.setTitle('Soundbites');
    await windowManager.setMinimumSize(const Size(900, 600));
  } catch (_) {}

  final demo = Platform.environment['SOUNDBITES_DEMO_LIBRARY'];
  final SoundbitesController controller;
  if (demo != null && demo.isNotEmpty) {
    controller = DemoController(demo);
  } else {
    final appData = await getApplicationSupportDirectory();
    final instance = InstanceLock(appData.path);
    if (!await instance.tryAcquire()) {
      runApp(const AlreadyRunningApp());
      return;
    }
    final engine = Engine(appDataDir: appData.path, version: appVersion);
    final ec = EngineController(engine: engine, toolsDir: p.join(appData.path, 'tools'), ffmpegPath: ffmpegPath(), skipTools: Platform.isLinux);
    await ec.start();
    controller = ec;
  }
  runApp(SoundbitesApp(controller: controller));
}

/// Shown instead of the library when another copy of Soundbites is already open.
class AlreadyRunningApp extends StatelessWidget {
  const AlreadyRunningApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Soundbites',
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Soundbites is already running', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  const Text('Use the window that is already open. Close this one.'),
                  const SizedBox(height: 24),
                  FilledButton(onPressed: () => exit(0), child: const Text('Close')),
                ],
              ),
            ),
          ),
        ),
      );
}
