import 'package:flutter/material.dart';

import '../engine/state.dart';
import 'controller.dart';
import 'screens/first_launch.dart';
import 'screens/library_screen.dart';
import 'theme.dart';
import 'widgets/player.dart';

class SoundbitesApp extends StatefulWidget {
  const SoundbitesApp({super.key, required this.controller});
  final SoundbitesController controller;
  @override
  State<SoundbitesApp> createState() => _SoundbitesAppState();
}

class _SoundbitesAppState extends State<SoundbitesApp> {
  final player = PlayerModel();

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Soundbites',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: ValueListenableBuilder<AppState>(
        valueListenable: widget.controller.state,
        builder: (context, s, _) => s.library.status == LibraryStatus.open
            ? ListenableBuilder(listenable: player, builder: (_, _) => LibraryScreen(state: s, controller: widget.controller, player: player))
            : FirstLaunchScreen(state: s, controller: widget.controller),
      ),
    );
  }
}
