import 'package:flutter/material.dart';

import '../format.dart';
import '../theme.dart';
import 'player.dart';

/// The bottom bar: what is playing, play/pause, a scrubber, and the elapsed time.
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key, required this.player});
  final PlayerModel player;

  @override
  Widget build(BuildContext context) {
    final c = context.sb;
    final np = player.current;
    if (np == null) return const SizedBox.shrink();
    final dur = player.duration ?? Duration.zero;
    final pos = player.position;
    final max = dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(color: c.panel, border: Border(top: BorderSide(color: c.line))),
      child: Row(children: [
        IconButton.filled(onPressed: player.toggle, icon: Icon(player.playing ? Icons.pause : Icons.play_arrow)),
        const SizedBox(width: 12),
        SizedBox(
          width: 260,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(np.track.title ?? np.track.id, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text('${np.track.artist ?? ''}${np.kind == 'full' ? '  ·  full track' : '  ·  30 s clip'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.muted)),
          ]),
        ),
        const SizedBox(width: 12),
        Text(fmtTime(pos.inMilliseconds / 1000), style: TextStyle(fontSize: 12, color: c.muted)),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
            child: Slider(value: pos.inMilliseconds.clamp(0, max.toInt()).toDouble(), max: max, onChanged: (v) => player.seek(Duration(milliseconds: v.round()))),
          ),
        ),
        Text(fmtTime(dur.inMilliseconds / 1000), style: TextStyle(fontSize: 12, color: c.muted)),
        const SizedBox(width: 8),
        IconButton(tooltip: 'Stop', onPressed: player.stop, icon: const Icon(Icons.close)),
      ]),
    );
  }
}
