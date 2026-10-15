import 'package:flutter_test/flutter_test.dart';
import 'package:soundbites/engine/library.dart';
import 'package:soundbites/engine/views.dart';

Track t(Map<String, dynamic> extra) => Track(<String, dynamic>{
      'id': 'x',
      'first_seen': '2026-01-01',
      'runs': <String>[],
      'clip': null,
      'clip_present': false,
      ...extra,
    });

/// The saved views of the default profile (libraryOpen.ts defaultProfile), rules only.
final Map<String, Map<String, dynamic>> saved = {
  'instrumental': {
    'any': [
      {'field': 'mood', 'contains': 'instrumental'},
      {'field': 'mood', 'contains': 'ambient'},
      {'field': 'suits', 'contains': 'no vocal'},
      {'field': 'suits', 'contains': 'instrumental'},
    ]
  },
  'high-energy': {
    'any': [
      {'field': 'energy', 'equals': 'high'}
    ]
  },
  'low-energy': {
    'any': [
      {'field': 'energy', 'equals': 'low'}
    ]
  },
};

void main() {
  group('saved view rules', () {
    test('high energy = energy is high', () {
      expect(ruleMatches(t({'energy': 'high'}), saved['high-energy']), isTrue);
      expect(ruleMatches(t({'energy': 'medium'}), saved['high-energy']), isFalse);
      expect(ruleMatches(t({}), saved['high-energy']), isFalse);
    });

    test('instrumental looks at mood and suits', () {
      expect(
          ruleMatches(
              t({
                'mood': ['hard techno', 'instrumental']
              }),
              saved['instrumental']),
          isTrue);
      expect(ruleMatches(t({'suits': 'Steady club build, no vocal until late'}), saved['instrumental']), isTrue);
      expect(
          ruleMatches(
              t({
                'mood': ['vocal-led']
              }),
              saved['instrumental']),
          isFalse);
    });

    test('a missing or bad rule shows everything', () {
      expect(ruleMatches(t({}), null), isTrue);
      expect(ruleMatches(t({}), {'any': <dynamic>[]}), isTrue);
      expect(
          isValidRule({
            'any': [
              {'field': 'energy', 'equals': 'low'}
            ]
          }),
          isTrue);
      expect(describeRule(null), 'shows everything');
      expect(describeRule('nope'), 'shows everything');
    });

    test('bpm ranges and descriptions', () {
      expect(
          ruleMatches(t({'bpm': 128}), {
            'all': [
              {'field': 'bpm', 'min': 120, 'max': 140}
            ]
          }),
          isTrue);
      expect(
          ruleMatches(t({'bpm': 90}), {
            'all': [
              {'field': 'bpm', 'min': 120}
            ]
          }),
          isFalse);
      expect(
          ruleMatches(t({}), {
            'all': [
              {'field': 'bpm', 'min': 120}
            ]
          }),
          isFalse);
      expect(
          ruleMatches(t({'bpm': 128}), {
            'all': [
              {'field': 'bpm', 'equals': '128'}
            ]
          }),
          isTrue);
      expect(describeRule(saved['high-energy']), 'energy is "high"');
      expect(
          describeRule({
            'all': [
              {'field': 'bpm', 'min': 120, 'max': 140},
              {'field': 'mood', 'contains': 'techno'}
            ]
          }),
          'bpm between 120 and 140 and mood contains "techno"');
      expect(
          describeRule({
            'any': [
              {'field': 'energy', 'equals': 'high'}
            ],
            'all': [
              {'field': 'bpm', 'min': 120.0}
            ]
          }),
          'energy is "high", and bpm at least 120');
    });

    test('any and all combine; a condition with no operator never matches', () {
      final rule = {
        'any': [
          {'field': 'energy', 'equals': 'high'},
          {'field': 'energy', 'equals': 'medium'}
        ],
        'all': [
          {'field': 'platform', 'contains': 'tiktok'}
        ]
      };
      expect(ruleMatches(t({'energy': 'medium', 'platform': 'TikTok'}), rule), isTrue);
      expect(ruleMatches(t({'energy': 'low', 'platform': 'TikTok'}), rule), isFalse);
      expect(ruleMatches(t({'energy': 'high', 'platform': 'Reels'}), rule), isFalse);
      expect(
          conditionMatches(t({'energy': 'high'}), {'field': 'energy'}), isFalse);
    });
  });
}
