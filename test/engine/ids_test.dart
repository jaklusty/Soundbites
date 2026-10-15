import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundbites/engine/ids.dart';

void main() {
  final cases = (jsonDecode(File('test/fixtures/slugify-oracle.json').readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  group('slugify matches the Python oracle', () {
    test('reproduces every id in the real library.json (first 87 cases carry the stored id)', () {
      final real = cases.where((c) => c.containsKey('expect')).toList();
      expect(real.length, 87);
      final wrong = real.where((c) => slugify(c['artist'] as String?, c['title'] as String?) != c['expect']).toList();
      expect(wrong, isEmpty, reason: jsonEncode(wrong.take(5).toList()));
    });

    test('matches the Python function on every crafted and random case', () {
      final wrong = <Map<String, dynamic>>[];
      for (final c in cases) {
        final got = slugify(c['artist'] as String?, c['title'] as String?);
        if (got != c['id']) wrong.add({...c, 'got': got});
      }
      expect(wrong.length, 0, reason: const JsonEncoder.withIndent(' ').convert(wrong.take(5).toList()));
      expect(cases.length, greaterThan(3000));
    });

    test('is stable for the documented behaviours', () {
      expect(slugify('Sabrina Carpenter', 'Espresso'), slugify('sabrina carpenter', 'ESPRESSO'));
      expect(slugify('a-b', 'c'), isNot(slugify('a', 'b-c')));
      expect(slugify('', '🎵'), matches(r'^track-[0-9a-f]{8}$'));
      expect(slugify('', '🎵'), isNot(slugify('', '🔥')));
      expect(slugify('宇多田ヒカル', 'First Love'), matches(r'^first-love-[0-9a-f]{8}$'));
      expect(slugify(null, null), matches(r'^track-[0-9a-f]{8}$'));
      expect(slugify('A' * 60, 'B' * 60), matches(r'^a{50}-[0-9a-f]{8}$'));
    });

    test('casefold follows Python where toLowerCase does not', () {
      expect(casefold('Straße'), 'strasse');
      expect(casefold('ΟΔΥΣΣΕΥΣ'), 'οδυσσευσ');
      expect(casefold('İ'), 'i̇');
    });
  });
}
