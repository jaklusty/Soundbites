/// Small formatting helpers shared by the widgets.
library;

String fmtUses(int? n) {
  if (n == null) return '';
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '')}m uses';
  if (n >= 1000) return '${(n / 1000).round()}k uses';
  return '$n uses';
}

String fmtTime(double sec) {
  final total = sec.round();
  final m = total ~/ 60;
  final s = total % 60;
  return '$m:${s < 10 ? '0' : ''}$s';
}

String fmtMb(num bytes) {
  final mb = bytes / 1e6;
  if (mb >= 10) return '${mb.toStringAsFixed(0)} MB';
  if (mb >= 1) return '${mb.toStringAsFixed(1)} MB';
  return '${(bytes / 1e3).round()} KB';
}

String fmtWhen(String? iso, {DateTime? now}) {
  if (iso == null || iso.isEmpty) return 'never';
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  final mins = ((now ?? DateTime.now()).difference(d).inSeconds / 60).round();
  if (mins < 1) return 'just now';
  if (mins < 60) return '$mins min ago';
  if (mins < 60 * 24) return '${(mins / 60).round()} h ago';
  return '${d.toLocal().day}/${d.toLocal().month} ${d.toLocal().hour.toString().padLeft(2, '0')}:${d.toLocal().minute.toString().padLeft(2, '0')}';
}

String hookLabel(String? method) {
  const names = {'heatmap': 'most replayed', 'chorus': 'chorus', 'energy': 'loudest part', 'explicit': 'set by hand', 'default': 'not detected'};
  return names[method ?? ''] ?? (method ?? '');
}
