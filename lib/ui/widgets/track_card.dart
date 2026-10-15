import 'package:flutter/material.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../../engine/library.dart';
import '../../engine/state.dart';
import '../controller.dart';
import '../format.dart';
import '../sections.dart';
import '../theme.dart';
import 'badges.dart';
import 'player.dart';

class TrackCard extends StatefulWidget {
  const TrackCard({super.key, required this.track, required this.state, required this.controller, required this.player});
  final Track track;
  final AppState state;
  final SoundbitesController controller;
  final PlayerModel player;

  @override
  State<TrackCard> createState() => _TrackCardState();
}

class _TrackCardState extends State<TrackCard> {
  bool linkOpen = false;
  final linkCtl = TextEditingController();
  bool busy = false;

  Track get t => widget.track;

  @override
  void dispose() {
    linkCtl.dispose();
    super.dispose();
  }

  Future<void> _act(Future<void> Function() fn) async {
    setState(() => busy = true);
    try {
      await fn();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _wrongTrack() async {
    var removeFull = false;
    if (t.full != null) {
      removeFull = await _confirm('This track also has a full download (${t.full!.split('/').last}). Remove that too?') ?? false;
    }
    final ok = await _confirm('Mark "${t.title}" as the wrong track? The clip will be removed, this upload will never be matched again, and the next search result will be tried.');
    if (ok == true) await _act(() => widget.controller.wrongTrack(t.id, removeFull));
  }

  Future<bool?> _confirm(String text) => showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          content: Text(text),
          actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('No')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Yes'))],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = context.sb;
    final s = widget.state;
    final isFav = s.favourites.contains(t.id);
    final playing = widget.player.current?.track.id == t.id && widget.player.playing;
    final isCurrent = widget.player.current?.track.id == t.id;
    final clipPath = widget.controller.mediaPath('clip', t.id);
    final fullPath = widget.controller.mediaPath('full', t.id);
    final src = safeMediaUrl(t.userSourceUrl ?? t.sourceUrl);
    final bits = <String>[
      if (t.bpm != null) '${t.bpm} bpm',
      if (t.energy != null) '${t.energy} energy',
      if (t.mood.isNotEmpty) t.mood.join(', '),
      if (t.platform != null) t.platform == 'both' ? 'TikTok + Reels' : t.platform!,
    ];
    final mv = trendLine(t);
    final finder = Theme.of(context).platform == TargetPlatform.windows ? 'Show in Explorer' : 'Show in Finder';

    return Opacity(
      opacity: t.clipPresent ? 1 : .65,
      child: Container(
        margin: const EdgeInsets.only(bottom: 7),
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
        decoration: BoxDecoration(
          color: isCurrent ? Theme.of(context).colorScheme.primary.withValues(alpha: .07) : c.panel,
          border: Border.all(color: isCurrent ? Theme.of(context).colorScheme.primary : c.line),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _PlayButton(
              enabled: t.clipPresent && clipPath != null,
              playing: playing,
              onPressed: clipPath == null ? null : () => widget.player.play(t, clipPath, 'clip'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(TextSpan(children: [
                    TextSpan(text: t.title ?? t.id, style: const TextStyle(fontWeight: FontWeight.w600)),
                    if ((t.artist ?? '').isNotEmpty) TextSpan(text: '  ·  ${t.artist}', style: TextStyle(color: c.muted)),
                  ])),
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 7,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (t.direction != null && !t.pinned) DirectionBadge(t.direction!),
                      if (t.licence == 'clearable') Pill('clearable', fg: Theme.of(context).colorScheme.primary, bg: Theme.of(context).colorScheme.primary.withValues(alpha: .1)),
                      if (t.pinned) Pill('extra', fg: c.rising, bg: c.risingBg),
                      for (final b in bits) Text(b, style: TextStyle(fontSize: 12.5, color: c.muted)),
                      if (t.hookAt != null)
                        Tooltip(
                          message: t.hookDetail ?? '',
                          child: Text('hook at ${fmtTime(t.hookAt!)} (${hookLabel(t.hookMethod)})', style: TextStyle(fontSize: 12.5, color: c.muted)),
                        ),
                      if (src != null)
                        InkWell(onTap: () => widget.controller.openExternal(src), child: Text('source', style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.primary))),
                    ],
                  ),
                  if (t.suits != null) Padding(padding: const EdgeInsets.only(top: 5), child: Text(t.suits!, style: TextStyle(fontSize: 13, color: c.muted))),
                  _matchLine(context),
                  if (!t.clipPresent)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        t.matchStatus == 'no-confident-match'
                            ? 'No clip for this one yet.'
                            : (t.sourceUrl != null || t.userSourceUrl != null || t.runs.isNotEmpty)
                                ? 'Clip not on disk. The research is kept.'
                                : 'No source could be found for this one.',
                        style: TextStyle(fontSize: 12.5, color: c.faint, fontStyle: FontStyle.italic),
                      ),
                    ),
                  _fullLine(context, fullPath),
                  if (widget.player.error != null && isCurrent) Padding(padding: const EdgeInsets.only(top: 4), child: Text(widget.player.error!, style: TextStyle(fontSize: 12.5, color: c.peaking))),
                  const SizedBox(height: 7),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if (t.clipPresent && clipPath != null) _DragHandle(path: clipPath, label: 'drag clip'),
                      if (t.clipPresent) SmallButton(finder, onPressed: () => widget.controller.showInFolder('clip', t.id)),
                      if (!t.clipPresent)
                        SmallButton(t.matchStatus == 'no-confident-match' || t.hookAt == null ? 'Try again' : 'Get clip again', onPressed: busy ? null : () => _act(() => widget.controller.retryTrack(t.id))),
                      if (t.clipPresent || t.match != null) SmallButton('Wrong track', onPressed: busy ? null : _wrongTrack),
                      SmallButton('Paste a YouTube link', onPressed: () => setState(() => linkOpen = !linkOpen)),
                    ],
                  ),
                  if (linkOpen)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(children: [
                        Expanded(child: TextField(controller: linkCtl, decoration: const InputDecoration(hintText: 'https://www.youtube.com/watch?v=…'), onSubmitted: (_) => _submitLink())),
                        const SizedBox(width: 6),
                        FilledButton(onPressed: busy ? null : _submitLink, child: const Text('Use this link')),
                      ]),
                    ),
                  if (linkOpen) Text('The clip will be cut from this upload instead. A link you set is never replaced by a later feed run.', style: TextStyle(fontSize: 12, color: c.faint)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: 'Favourite (keeps the clip and pulls the full track)',
                  icon: Icon(isFav ? Icons.star_rounded : Icons.star_outline_rounded, color: isFav ? c.star : c.faint),
                  onPressed: busy ? null : () => _act(() => widget.controller.star(t.id, !isFav)),
                ),
                if (t.uses != null) Text(fmtUses(t.uses), style: TextStyle(fontSize: 11.5, color: c.faint)),
                if (mv.isNotEmpty) Text(mv, style: TextStyle(fontSize: 11.5, color: c.faint)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submitLink() async {
    final v = linkCtl.text.trim();
    if (v.isEmpty) return;
    await _act(() => widget.controller.setTrackLink(t.id, v));
    if (mounted) setState(() => linkOpen = false);
  }

  Widget _matchLine(BuildContext context) {
    final c = context.sb;
    final style = TextStyle(fontSize: 12, color: c.faint);
    final bold = TextStyle(fontSize: 12, color: c.muted, fontWeight: FontWeight.w600);
    Widget line(String b, String rest) => Padding(padding: const EdgeInsets.only(top: 4), child: Text.rich(TextSpan(children: [TextSpan(text: b, style: bold), TextSpan(text: rest, style: style)])));
    if (t.matchStatus == 'user-link') return line('Link set by you', ' · ${t.userSourceUrl ?? ''}');
    if (t.matchStatus == 'no-confident-match') return line('No confident match', ' · the search result did not mention this title or artist, so nothing was downloaded.');
    final m = t.match;
    if (m != null) {
      final d = m['duration'] is num ? ' · ${fmtTime((m['duration'] as num).toDouble())}' : '';
      return line('Matched', ' "${m['title']}" by ${m['channel']}$d');
    }
    if (t.clipPresent || t.sourceUrl != null) return line('Match', ' not recorded');
    return const SizedBox.shrink();
  }

  Widget _fullLine(BuildContext context, String? fullPath) {
    final c = context.sb;
    final s = widget.state;
    final style = TextStyle(fontSize: 12.5, color: c.muted);
    if (t.full != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Wrap(spacing: 7, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Pill('full track', fg: c.star, bg: c.peakingBg),
          if (fullPath != null) _DragHandle(path: fullPath, label: t.full!.split('/').last),
          if (t.fullBytes != null) Text(fmtMb(t.fullBytes!), style: style),
          Text('drag it into Resolve, or', style: style),
          SmallButton(Theme.of(context).platform == TargetPlatform.windows ? 'Show in Explorer' : 'Show in Finder', onPressed: () => widget.controller.showInFolder('full', t.id)),
          if (fullPath != null) SmallButton('Play full', icon: Icons.play_arrow, onPressed: () => widget.player.play(t, fullPath, 'full')),
        ]),
      );
    }
    if (s.promoteQueue.contains(t.id) || s.promoting == t.label) {
      return Padding(padding: const EdgeInsets.only(top: 6), child: Text('Pulling the full track…', style: TextStyle(fontSize: 12.5, color: c.faint, fontStyle: FontStyle.italic)));
    }
    if (t.fullError != null) {
      return Padding(padding: const EdgeInsets.only(top: 6), child: Text('Full track could not be pulled (${t.fullError}). The audition clip still works.', style: TextStyle(fontSize: 12.5, color: c.faint, fontStyle: FontStyle.italic)));
    }
    return const SizedBox.shrink();
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.enabled, required this.playing, this.onPressed});
  final bool enabled, playing;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final c = context.sb;
    final primary = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: 38,
      height: 38,
      child: Material(
        shape: CircleBorder(side: BorderSide(color: playing ? primary : c.line)),
        color: playing ? primary : Theme.of(context).scaffoldBackgroundColor,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onPressed : null,
          child: Icon(playing ? Icons.pause : Icons.play_arrow, size: 20, color: playing ? Colors.white : (enabled ? Theme.of(context).colorScheme.onSurface : c.faint)),
        ),
      ),
    );
  }
}

/// Drag a file out of the app with its real path (into DaVinci Resolve, Finder, anywhere).
class _DragHandle extends StatelessWidget {
  const _DragHandle({required this.path, required this.label});
  final String path, label;
  @override
  Widget build(BuildContext context) {
    final c = context.sb;
    return DragItemWidget(
      allowedOperations: () => [DropOperation.copy],
      dragItemProvider: (request) async {
        final item = DragItem(suggestedName: path.split(RegExp(r'[\\/]')).last);
        item.add(Formats.fileUri(Uri.file(path)));
        return item;
      },
      child: DraggableWidget(
        child: Tooltip(
          message: 'Drag into DaVinci Resolve',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(border: Border.all(color: c.line), borderRadius: BorderRadius.circular(6)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.drag_indicator, size: 14, color: c.muted), const SizedBox(width: 4), Text(label, style: TextStyle(fontSize: 12, color: c.muted))]),
          ),
        ),
      ),
    );
  }
}
