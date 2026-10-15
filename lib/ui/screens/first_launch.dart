import 'package:flutter/material.dart';

import '../../engine/state.dart';
import '../controller.dart';
import '../format.dart';
import '../theme.dart';

/// Everything shown before a library is open: choose a folder, start a new library, a missing
/// drive, a lock held elsewhere, a stale lock, or a damaged library.
class FirstLaunchScreen extends StatelessWidget {
  const FirstLaunchScreen({super.key, required this.state, required this.controller});
  final AppState state;
  final SoundbitesController controller;

  @override
  Widget build(BuildContext context) {
    final L = state.library;
    final c = context.sb;
    Widget path() => L.path == null
        ? const SizedBox.shrink()
        : Container(
            margin: const EdgeInsets.symmetric(vertical: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(color: c.panel, border: Border.all(color: c.line), borderRadius: BorderRadius.circular(6)),
            child: Text(L.path!, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
          );
    Widget choose([String label = 'Choose a different folder…']) => OutlinedButton(onPressed: controller.chooseLibraryFolder, child: Text(label));
    Widget retry() => FilledButton(onPressed: controller.reopenLibrary, child: const Text('Try again'));

    final (title, body, actions) = switch (L.status) {
      LibraryStatus.none => (
          'Soundbites',
          'Choose the folder where your sound library lives. If you have one already, pick it; if not, pick an empty folder and Soundbites will start a new library there.\n\nOn a Mac the Movies folder is a good home. On Windows, Videos or Music. Avoid iCloud or OneDrive folders: they can offload files while you are editing.',
          <Widget>[FilledButton(onPressed: controller.chooseLibraryFolder, child: const Text('Choose folder…'))],
        ),
      LibraryStatus.missing => (
          'Library not found',
          'The library folder is not where it was last time. If it is on an external drive, plug it in and try again. Nothing has been changed and no new library has been created.',
          <Widget>[retry(), choose()],
        ),
      LibraryStatus.empty => (
          'Start a new library here?',
          'This folder has no library in it yet.',
          <Widget>[FilledButton(onPressed: () => controller.createLibraryHere(L.path!), child: const Text('Yes, start a new library here')), choose()],
        ),
      LibraryStatus.held => (
          'Library in use',
          'Another copy of Soundbites is using this library: ${L.owner?.app ?? 'Soundbites'} on ${L.owner?.host ?? '?'} (user ${L.owner?.user ?? '?'}), last seen ${fmtWhen(L.owner?.heartbeat)}. Only one can write at a time.',
          <Widget>[retry(), choose()],
        ),
      LibraryStatus.stale => (
          'A previous session did not close properly',
          '${L.owner != null ? '${L.owner!.app} on ${L.owner!.host} left a lock behind ${fmtWhen(L.owner!.heartbeat)} and has not been seen since.' : 'A lock was left behind.'} If no other computer is using this library right now, you can take it over.',
          <Widget>[FilledButton(onPressed: controller.takeOverLock, child: const Text('Take over')), choose()],
        ),
      LibraryStatus.error => (
          'This library could not be opened',
          '${L.message ?? ''}\n\nNothing has been changed.',
          <Widget>[retry(), choose()],
        ),
      LibraryStatus.open => ('', '', <Widget>[]),
    };

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Text(body, style: TextStyle(color: c.muted, height: 1.5)),
              path(),
              for (final w in L.warnings)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: c.peakingBg, borderRadius: BorderRadius.circular(8)),
                  child: Text(w, style: TextStyle(color: c.peaking, fontSize: 13)),
                ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
            ]),
          ),
        ),
      ),
    );
  }
}
