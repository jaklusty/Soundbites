import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundbites/engine/hook.dart';

void main() {
  final cases = (jsonDecode(File('test/fixtures/heatmap-oracle.json').readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();
  double? dur(Map<String, dynamic> c) => (c['duration'] as num?)?.toDouble();

  group('heatmap hook detection matches hook.py', () {
    test('agrees with the Python on every oracle case', () {
      final wrong = <String>[];
      for (final c in cases) {
        final got = fromHeatmap(c['heatmap'], dur(c));
        final exp = c['result'] as List?;
        if (exp == null && got == null) continue;
        if (exp == null ||
            got == null ||
            (got.at - (exp[0] as num).toDouble()).abs() > 1e-6 ||
            got.detail != exp[1]) {
          wrong.add('${c['name']}: got $got expected $exp');
        }
      }
      expect(wrong, isEmpty, reason: wrong.take(5).join('\n'));
      expect(cases.where((c) => c['result'] != null).length, greaterThan(50));
    });

    test('rejects garbage', () {
      expect(fromHeatmap(null, 100), isNull);
      expect(
          fromHeatmap([
            {'start_time': 'x', 'end_time': 1, 'value': 1}
          ], 100),
          isNull);
      expect(fromHeatmap('nope', 100), isNull);
    });
  });

  group('energy and the cascade', () {
    test('finds the loudest sustained window', () {
      const hop = 8192 / 22050;
      final n = (200 / hop).floor();
      final rms = List<double>.generate(n, (i) {
        final t = i * hop;
        return t >= 90 && t < 125 ? 0.9 : 0.1;
      });
      final r = fromEnergy(rms, hop, 200)!;
      expect(r.detail, 'loudest sustained window');
      expect(r.at, greaterThan(85));
      expect(r.at, lessThan(95));
    });

    test('short track → 0', () {
      expect(fromEnergy(List<double>.filled(10, 0), 0.37, 20), (at: 0.0, detail: 'track shorter than the clip'));
    });

    test('explicit wins, then heatmap, then energy, then 0:20', () async {
      final withResult = cases.firstWhere((c) => c['result'] != null);
      expect((await detect(explicit: 42, info: {'heatmap': withResult['heatmap']})).method, 'explicit');
      final withMap = cases.firstWhere((c) => c['result'] != null && c['duration'] != null);
      expect((await detect(info: {'heatmap': withMap['heatmap'], 'duration': withMap['duration']})).method, 'heatmap');
      const hop = 8192 / 22050;
      final rms = List<double>.filled(400, 0.1);
      for (var i = 150; i < 250; i++) {
        rms[i] = 1;
      }
      final e = await detect(
        info: {'heatmap': <dynamic>[]},
        measureRms: () async => RmsResult(rms: rms, hop: hop, duration: 400 * hop),
      );
      expect(e.method, 'energy');
      final d = await detect(info: {});
      expect(d, const HookResult(at: 20, method: 'default', detail: 'no signal — used 0:20'));
    });

    test('fmt', () {
      expect(fmt(0), '0:00');
      expect(fmt(65.4), '1:05');
      expect(fmt(273.8), '4:34');
    });
  });
}
