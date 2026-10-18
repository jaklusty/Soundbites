import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../engine/state.dart';
import '../../engine/views.dart';
import '../controller.dart';
import '../format.dart';
import '../sections.dart';
import '../theme.dart';
import '../widgets/player.dart';
import '../widgets/player_bar.dart';
import '../widgets/track_card.dart';
import 'settings_panel.dart';

/// The library: a sidebar of sections, filters and saved views; search on top; the track list;
/// the player bar at the bottom.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.state, required this.controller, required this.player});
  final AppState state;
  final SoundbitesController controller;
  final PlayerModel player;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final searchCtl = TextEditingController();
  final searchFocus = FocusNode();
  String query = '';
  Filter filter = Filter.all;
  String? sectionKey; // null = all sections
  bool settingsOpen = false;
  bool aboutOpen = false;

  @override
  void dispose() {
    searchCtl.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final c = context.sb;
    final list = visibleTracks(s, query: query, filter: filter);
    final sections = buildSections(s, list);
    final shown = sectionKey == null ? sections : sections.where((x) => x.key == sectionKey).toList();
    final storage = storageSummary(s.tracks);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.slash): () => searchFocus.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.escape): () {
          searchCtl.clear();
          setState(() => query = '');
          searchFocus.unfocus();
        },
        const SingleActivator(LogicalKeyboardKey.space): () {
          if (!searchFocus.hasFocus) widget.player.toggle();
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Row(children: [
            _Sidebar(
              state: s,
              sections: sections,
              sectionKey: sectionKey,
              filter: filter,
              onSection: (k) => setState(() => sectionKey = k),
              onFilter: (f) => setState(() => filter = f),
              onView: (k) => widget.controller.setActiveView(k),
              onSettings: () => setState(() {
                settingsOpen = !settingsOpen;
                aboutOpen = false;
              }),
              onAbout: () => setState(() {
                aboutOpen = !aboutOpen;
                settingsOpen = false;
              }),
              storage: storage,
            ),
            Expanded(
              child: Column(children: [
                _TopBar(controller: searchCtl, focus: searchFocus, onChanged: (v) => setState(() => query = v.trim()), state: s, ctl: widget.controller),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                    children: [
                      if (settingsOpen) SettingsPanel(state: s, controller: widget.controller),
                      if (aboutOpen) const AboutPanel(),
                      _Attention(state: s, controller: widget.controller),
                      if (shown.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text(
                            s.tracks.isEmpty ? 'No runs yet. The feed is checked automatically; new sounds appear here as they arrive.' : 'Nothing matches. Try clearing the search or filter.',
                            style: TextStyle(color: c.muted, fontStyle: FontStyle.italic),
                          ),
                        ),
                      for (final sec in shown) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 22, bottom: 10),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                              Text(sec.title.toUpperCase(), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.1, color: c.muted)),
                              const SizedBox(width: 9),
                              Text('${sec.tracks.length}', style: TextStyle(fontSize: 12, color: c.faint)),
                            ]),
                            const SizedBox(height: 4),
                            Text(sec.blurb, style: TextStyle(fontSize: 13, color: c.muted)),
                            const SizedBox(height: 6),
                            Divider(height: 1, color: c.line),
                          ]),
                        ),
                        for (final t in sec.tracks) TrackCard(key: ValueKey(t.id), track: t, state: s, controller: widget.controller, player: widget.player),
                      ],
                    ],
                  ),
                ),
                ListenableBuilder(listenable: widget.player, builder: (_, _) => PlayerBar(player: widget.player)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.state, required this.sections, required this.sectionKey, required this.filter, required this.onSection, required this.onFilter, required this.onView, required this.onSettings, required this.onAbout, required this.storage});
  final AppState state;
  final List<Section> sections;
  final String? sectionKey;
  final Filter filter;
  final void Function(String?) onSection;
  final void Function(Filter) onFilter;
  final void Function(String) onView;
  final VoidCallback onSettings, onAbout;
  final ({int tracked, int clips, int clipBytes, int fulls, int fullBytes}) storage;

  @override
  Widget build(BuildContext context) {
    final c = context.sb;
    final primary = Theme.of(context).colorScheme.primary;
    Widget item(String label, {required bool selected, required VoidCallback onTap, int? count, IconData? icon}) => InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(7),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: selected ? primary.withValues(alpha: .12) : null, borderRadius: BorderRadius.circular(7)),
            child: Row(children: [
              if (icon != null) ...[Icon(icon, size: 16, color: selected ? primary : c.muted), const SizedBox(width: 8)],
              Expanded(child: Text(label, style: TextStyle(fontSize: 13.5, color: selected ? primary : null, fontWeight: selected ? FontWeight.w600 : FontWeight.w400))),
              if (count != null) Text('$count', style: TextStyle(fontSize: 12, color: c.faint)),
            ]),
          ),
        );
    Widget head(String t) => Padding(padding: const EdgeInsets.fromLTRB(10, 18, 10, 6), child: Text(t.toUpperCase(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.1, color: c.faint)));

    final views = state.savedViews;
    return Container(
      width: 232,
      decoration: BoxDecoration(color: c.panel, border: Border(right: BorderSide(color: c.line))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
          child: Row(children: [
            Image.asset('assets/icon/icon.png', width: 26, height: 26),
            const SizedBox(width: 9),
            const Text('Soundbites', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: -.3)),
          ]),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 4), child: Text(state.lastRun != null ? 'Last run ${state.lastRun}' : 'No runs yet', style: TextStyle(fontSize: 12, color: c.muted))),
        Expanded(
          child: ListView(padding: const EdgeInsets.symmetric(horizontal: 8), children: [
            head('Library'),
            item('Everything', selected: sectionKey == null, onTap: () => onSection(null), icon: Icons.library_music_outlined, count: state.tracks.length),
            for (final sec in sections) item(sec.title.split(' — ').first, selected: sectionKey == sec.key, onTap: () => onSection(sec.key), count: sec.tracks.length),
            head('Filter'),
            for (final f in Filter.values)
              item(_filterLabel(f), selected: filter == f, onTap: () => onFilter(f), icon: f == Filter.favourite ? Icons.star_rounded : null),
            if (views.isNotEmpty) head('Saved views'),
            if (views.isNotEmpty) item('Show everything', selected: state.activeView.isEmpty, onTap: () => onView('')),
            for (final e in views.entries)
              Tooltip(
                message: describeRule((e.value as Map?)?['rule']),
                child: item(((e.value as Map?)?['label'] ?? e.key).toString(), selected: state.activeView == e.key, onTap: () => onView(e.key), icon: Icons.filter_alt_outlined),
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
          child: Text('${storage.tracked} tracked · ${storage.clips} clips (${fmtMb(storage.clipBytes)}) · ${storage.fulls} full (${fmtMb(storage.fullBytes)}) · ${state.favourites.length} favourites', style: TextStyle(fontSize: 11.5, color: c.faint, height: 1.4)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
          child: Row(children: [
            Expanded(child: item('Settings', selected: false, onTap: onSettings, icon: Icons.settings_outlined)),
            Expanded(child: item('About', selected: false, onTap: onAbout, icon: Icons.info_outline)),
          ]),
        ),
      ]),
    );
  }

  String _filterLabel(Filter f) => switch (f) {
        Filter.all => 'All',
        Filter.rising => 'Rising',
        Filter.peaking => 'Peaking',
        Filter.favourite => 'Favourites',
        Filter.clearable => 'Clearable',
        Filter.pool => 'Extras',
        Filter.playable => 'Has clip',
        Filter.noAudio => 'No clip',
      };
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.controller, required this.focus, required this.onChanged, required this.state, required this.ctl});
  final TextEditingController controller;
  final FocusNode focus;
  final void Function(String) onChanged;
  final AppState state;
  final SoundbitesController ctl;

  @override
  Widget build(BuildContext context) {
    final c = context.sb;
    final f = state.feed;
    final d = f.downloading;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 10),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.line))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focus,
              onChanged: onChanged,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 18), hintText: 'Search title, artist, mood, what it suits…  (press / to search)'),
            ),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(onPressed: ctl.checkFeedNow, icon: const Icon(Icons.refresh, size: 16), label: const Text('Check feed')),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('Feed checked ${fmtWhen(f.lastChecked)}${f.lastResult != null ? ' (${f.lastResult})' : ''}', style: TextStyle(fontSize: 12.5, color: c.muted)),
          if (f.runsWaiting > 0) Text('· ${f.runsWaiting} run(s) waiting', style: TextStyle(fontSize: 12.5, color: c.muted)),
          if (d != null) ...[
            Text('· Run ${d.run}: ${d.done} of ${d.total}${d.current != null ? ' · ${d.current}' : ''}', style: TextStyle(fontSize: 12.5, color: c.muted)),
            SizedBox(width: 140, child: LinearProgressIndicator(value: d.total == 0 ? null : d.done / d.total, minHeight: 6, borderRadius: BorderRadius.circular(3))),
            TextButton(onPressed: () => ctl.pauseDownloads(!d.paused), child: Text(d.paused ? 'Resume' : 'Pause')),
            TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(content: const Text('Stop the current run? Clips already saved are kept; the run resumes next time.'), actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep going')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Stop'))]));
                if (ok == true) await ctl.cancelDownloads();
              },
              child: const Text('Cancel'),
            ),
          ],
          if (state.promoting != null) Text('· Pulling full track: ${state.promoting}', style: TextStyle(fontSize: 12.5, color: c.muted)),
        ]),
      ]),
    );
  }
}

/// Needs attention: health issues, pending files, library warnings, tool problems, reclaimable
/// space and the newer-version notice. Nothing fails silently into a log.
class _Attention extends StatelessWidget {
  const _Attention({required this.state, required this.controller});
  final AppState state;
  final SoundbitesController controller;

  @override
  Widget build(BuildContext context) {
    final c = context.sb;
    final s = state;
    final lines = <Widget>[];
    for (var i = 0; i < s.issues.length; i++) {
      final e = s.issues[i];
      lines.add(Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Text.rich(TextSpan(children: [TextSpan(text: e.message, style: const TextStyle(fontWeight: FontWeight.w600)), if (e.detail.isNotEmpty) TextSpan(text: '  ·  ${e.detail}')]))),
        IconButton(visualDensity: VisualDensity.compact, iconSize: 16, onPressed: () => controller.clearIssue(i), icon: const Icon(Icons.close), tooltip: 'Dismiss'),
      ]));
    }
    if (s.pending.isNotEmpty) lines.add(Text('${s.pending.length} run file(s) waiting in pending/. They are picked up automatically.', style: const TextStyle(fontWeight: FontWeight.w600)));
    for (final w in s.library.warnings) {
      lines.add(Text(w, style: const TextStyle(fontWeight: FontWeight.w600)));
    }
    if (s.tools.message != null) lines.add(Text(s.tools.message!, style: const TextStyle(fontWeight: FontWeight.w600)));

    final blocks = <Widget>[];
    if (lines.isNotEmpty) {
      blocks.add(_box(context, c.peakingBg, c.peaking, [const Text('Needs attention', style: TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 4), ...lines]));
    } else if (s.lastRunSummary != null) {
      final r = s.lastRunSummary!;
      blocks.add(_box(context, c.panel, c.muted, [Text('Last run ${r['run']} — ${r['added']} new, ${r['updated']} updated${(r['no_audio'] ?? 0) != 0 ? ', ${r['no_audio']} without audio' : ''}. Everything is up to date.')], border: true));
    }
    if (s.retryableCount > 0 && s.feed.queueLength == 0) {
      blocks.add(_box(context, c.panel, c.muted, [
        Text('${s.retryableCount} recent track(s) have no clip yet.'),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(onPressed: () => controller.retryAllNoAudio(), child: Text('Try again for all ${s.retryableCount}')),
        ),
      ], border: true));
    }
    if (s.reclaimableCount > 0) {
      blocks.add(_box(context, c.panel, c.muted, [
        Text('${s.reclaimableCount} full track(s) you have unstarred are still using ${fmtMb(s.reclaimableBytes)}.'),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: () async {
              final r = await controller.reclaim();
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Freed ${fmtMb(r.freed)} from ${r.removed} full track(s).')));
            },
            child: const Text('Free that space'),
          ),
        ),
      ], border: true));
    }
    if (s.update != null) {
      blocks.add(_box(context, c.panel, c.muted, [
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('A newer version of Soundbites is available (${s.update!.version}). '),
          InkWell(onTap: () => controller.openExternal(s.update!.url), child: Text('Download it', style: TextStyle(color: Theme.of(context).colorScheme.primary))),
        ]),
      ], border: true));
    }
    return Column(children: blocks);
  }

  Widget _box(BuildContext context, Color bg, Color fg, List<Widget> children, {bool border = false}) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.fromLTRB(13, 10, 13, 10),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(9), border: border ? Border.all(color: context.sb.line) : null),
        child: DefaultTextStyle(style: TextStyle(fontSize: 13, color: fg, height: 1.5), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children)),
      );
}
