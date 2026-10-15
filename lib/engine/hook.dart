/// Find the most recognisable 30 seconds of a track. Port of hook.py with the chorus method
/// dropped (never used in the library) and the energy method measured with ffmpeg instead of
/// librosa. Order: explicit hook_start → YouTube most-replayed heatmap → loudest 30 s window
/// (recorded as `energy`) → 0:20.
library;

import 'dart:math' as math;

import 'library.dart';

const double window = 30.0;
const double headSkip = 10.0;
const double tailSkip = 5.0;
const double flatnessMin = 1.25;
const double excessMin = 0.08;

/// 'explicit' | 'heatmap' | 'energy' | 'default'
class HookResult {
  const HookResult({required this.at, required this.method, required this.detail});
  final double at;
  final String method;
  final String detail;

  @override
  bool operator ==(Object other) =>
      other is HookResult && other.at == at && other.method == method && other.detail == detail;

  @override
  int get hashCode => Object.hash(at, method, detail);

  @override
  String toString() => 'HookResult(at: $at, method: $method, detail: $detail)';
}

/// What `measureRms` hands back: RMS values `hop` seconds apart, and the measured duration.
class RmsResult {
  const RmsResult({required this.rms, required this.hop, required this.duration});
  final List<double> rms;
  final double hop;
  final double duration;
}

double _clamp(double start, double? duration) {
  if (duration == null || duration == 0 || duration <= window) return 0.0;
  return math.max(0.0, math.min(start, duration - window));
}

/// JavaScript's Number(x) for the values a heatmap point can carry; null when it would be NaN.
double? _num(Object? v) {
  if (v is num) return v.isNaN ? null : v.toDouble();
  if (v == null) return null;
  if (v is bool) return v ? 1.0 : 0.0;
  if (v is String) {
    final s = v.trim();
    if (s.isEmpty) return 0.0;
    return double.tryParse(s);
  }
  return null;
}

/// Best 30 s window by detrended replay value. Returns null when the heatmap has no opinion.
({double at, String detail})? fromHeatmap(dynamic heatmap, double? duration) {
  if (heatmap is! List || heatmap.length < 8) return null;
  final pts = <(double, double, double)>[];
  for (final h in heatmap) {
    if (h is! Map) return null;
    final a = _num(h['start_time']), b = _num(h['end_time']), v = _num(h['value']);
    if (a == null || b == null || v == null) return null;
    pts.add((a, b, v));
  }

  final hasDuration = duration != null && duration != 0;
  var usable = pts.where((p) => p.$1 >= headSkip && (!hasDuration || p.$2 <= duration - tailSkip)).toList();
  if (usable.length < 5) usable = pts.length > 1 ? pts.sublist(1) : pts;
  if (usable.isEmpty) return null;

  final values = usable.map((p) => p.$3).toList();
  final mean = values.reduce((a, b) => a + b) / values.length;
  final peak = values.reduce(math.max);
  if (mean <= 0 || peak / mean < flatnessMin) return null;

  // Detrend: subtract a wide moving baseline and score only the excess.
  final n = usable.length;
  final span = math.max(3, n ~/ 5);
  final excess = <(double, double)>[];
  for (var i = 0; i < n; i++) {
    final lo = math.max(0, i - span);
    final hi = math.min(n, i + span + 1);
    var sum = 0.0;
    for (var k = lo; k < hi; k++) {
      sum += values[k];
    }
    final baseline = sum / (hi - lo);
    excess.add((usable[i].$1, math.max(0.0, usable[i].$3 - baseline)));
  }

  final peakExcess = excess.map((e) => e.$2).reduce(math.max);
  if (peakExcess < excessMin * mean) return null;

  // A hook rises into; drop-off never does.
  const lookback = window * 0.7;
  final byTime = <double, double>{};
  for (final p in usable) {
    byTime[p.$1] = p.$3;
  }
  bool risesInto(double start) {
    final before = <double>[];
    final inside = <double>[];
    for (final e in byTime.entries) {
      final a = e.key, v = e.value;
      if (start - lookback <= a && a < start) before.add(v);
      if (start <= a && a < start + window) inside.add(v);
    }
    if (before.isEmpty || inside.isEmpty) return false;
    return inside.reduce((x, y) => x + y) / inside.length > before.reduce((x, y) => x + y) / before.length;
  }

  double? bestStart;
  var bestScore = -1.0;
  for (final (start, _) in excess) {
    if (!risesInto(start)) continue;
    var score = 0.0;
    for (final (a, e) in excess) {
      if (start <= a && a < start + window) score += e;
    }
    if (score > bestScore) {
      bestScore = score;
      bestStart = start;
    }
  }
  if (bestStart == null || bestScore <= 0) return null;
  return (at: _clamp(bestStart, duration), detail: 'replay bump, peak ${(peak / mean).toStringAsFixed(1)}x average');
}

/// Loudest sustained 30 s. `rms` is a series of RMS values at `hop` seconds apart (the caller
/// measures it with ffmpeg). Mirrors from_energy in hook.py: candidate starts every hop from
/// HEAD_SKIP to duration-WINDOW-TAIL_SKIP, score = mean RMS inside the window.
({double at, String detail})? fromEnergy(List<double> rms, double hop, double? duration) {
  if (rms.isEmpty) return null;
  final times = List<double>.generate(rms.length, (i) => i * hop);
  var dur = duration ?? 0;
  if (dur == 0) dur = times.last;
  if (dur <= window) return (at: 0.0, detail: 'track shorter than the clip');
  double? bestStart;
  var bestScore = -1.0;
  for (var i = 0; i < times.length; i++) {
    final t = times[i];
    if (t < headSkip || t > dur - window - tailSkip) continue;
    var j = i;
    while (j < times.length && times[j] < t + window) {
      j++;
    }
    var sum = 0.0;
    for (var k = i; k < j; k++) {
      sum += rms[k];
    }
    final score = sum / math.max(1, j - i);
    if (score > bestScore) {
      bestScore = score;
      bestStart = t;
    }
  }
  if (bestStart == null) return null;
  return (at: _clamp(bestStart, dur), detail: 'loudest sustained window');
}

/// The cascade. [info] is the yt-dlp info dict (for `heatmap` and `duration`), if any;
/// [explicit] is a hook_start in seconds and always wins; [measureRms] lazily measures loudness
/// and is only called when the heatmap gives nothing.
Future<HookResult> detect({
  Json? info,
  double? duration,
  num? explicit,
  Future<RmsResult?> Function()? measureRms,
}) async {
  if (explicit != null) {
    return HookResult(at: explicit.toDouble(), method: 'explicit', detail: 'set in the run file');
  }
  final i = info ?? <String, dynamic>{};
  var dur = duration;
  if (dur == null || dur == 0) {
    final d = i['duration'];
    dur = d is num ? d.toDouble() : null;
  }

  final hm = fromHeatmap(i['heatmap'], dur);
  if (hm != null) return HookResult(at: hm.at, method: 'heatmap', detail: hm.detail);

  if (measureRms != null) {
    try {
      final m = await measureRms();
      if (m != null) {
        final e = fromEnergy(m.rms, m.hop, (dur == null || dur == 0) ? m.duration : dur);
        if (e != null) return HookResult(at: e.at, method: 'energy', detail: e.detail);
      }
    } catch (_) {
      // fall through to the default
    }
  }
  return const HookResult(at: 20.0, method: 'default', detail: 'no signal — used 0:20');
}

/// Seconds → "m:ss".
String fmt(double seconds) {
  final total = seconds.round();
  final m = total ~/ 60;
  final s = total % 60;
  return '$m:${s < 10 ? '0' : ''}$s';
}
