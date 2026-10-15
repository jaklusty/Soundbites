import 'package:flutter/material.dart';

import '../theme.dart';

class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, required this.fg, required this.bg});
  final String text;
  final Color fg, bg;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(5)),
        child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg, letterSpacing: .2)),
      );
}

class DirectionBadge extends StatelessWidget {
  const DirectionBadge(this.direction, {super.key});
  final String direction;
  @override
  Widget build(BuildContext context) {
    final c = context.sb;
    final (fg, bg) = switch (direction) {
      'rising' => (c.rising, c.risingBg),
      'peaking' => (c.peaking, c.peakingBg),
      _ => (c.fading, c.fadingBg),
    };
    return Pill(direction, fg: fg, bg: bg);
  }
}

class SmallButton extends StatelessWidget {
  const SmallButton(this.label, {super.key, this.onPressed, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  @override
  Widget build(BuildContext context) {
    final c = context.sb;
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
        minimumSize: const Size(0, 26),
        side: BorderSide(color: c.line),
        foregroundColor: c.muted,
        textStyle: const TextStyle(fontSize: 12),
      ),
      icon: icon == null ? const SizedBox.shrink() : Icon(icon, size: 14),
      label: Text(label),
    );
  }
}
