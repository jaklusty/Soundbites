/// Saved views: display rules over track fields. Views only change what is shown, never what is
/// captured. A view with no usable rule shows everything, so a bad rule can never hide the library.
///
/// A rule is the JSON from profile.json: `{any: [condition...], all: [condition...]}` where a
/// condition is `{field, equals?, contains?, min?, max?}` and field is one of energy, mood, suits,
/// direction, platform, licence, bpm, notes, title, artist.
library;

import 'library.dart';

String _fieldText(Track track, String field) {
  final v = track.json[field];
  if (v is List) return v.map((e) => e.toString()).join(' ').toLowerCase();
  if (v == null) return '';
  return v.toString().toLowerCase();
}

num? _asNum(Object? v) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v.trim());
  return null;
}

/// A number the way JavaScript prints it: integral doubles without the ".0".
String _numText(Object? v) {
  if (v is double && v.isFinite && v == v.truncateToDouble()) return v.toInt().toString();
  return v.toString();
}

/// Does one condition hold for the track?
bool conditionMatches(Track track, Map condition) {
  final field = condition['field'].toString();
  if (field == 'bpm') {
    final raw = track.json['bpm'];
    if (raw is! num || raw.isNaN) return false;
    final n = raw;
    final min = condition['min'], max = condition['max'], equals = condition['equals'];
    if (min != null && n < (_asNum(min) ?? double.nan)) return false;
    if (max != null && n > (_asNum(max) ?? double.nan)) return false;
    if (equals != null && n != _asNum(equals)) return false;
    return true;
  }
  final text = _fieldText(track, field);
  final equals = condition['equals'];
  if (equals != null) return text == equals.toString().toLowerCase();
  final contains = condition['contains'];
  if (contains != null) return text.contains(contains.toString().toLowerCase());
  return false;
}

List<Map> _conds(Map rule, String key) {
  final v = rule[key];
  if (v is! List) return const [];
  return v.whereType<Map>().toList();
}

/// A rule is usable when it is a map with at least one condition and every condition is a map
/// with a string `field`.
bool isValidRule(Object? rule) {
  if (rule is! Map) return false;
  final raw = <dynamic>[...?(rule['any'] as List?), ...?(rule['all'] as List?)];
  if (raw.isEmpty) return false;
  return raw.every((c) => c is Map && c['field'] is String);
}

/// Whether the track is shown under the rule. An invalid rule shows everything.
bool ruleMatches(Track track, Object? rule) {
  if (!isValidRule(rule)) return true;
  final r = rule as Map;
  final any = _conds(r, 'any');
  final all = _conds(r, 'all');
  final anyOk = r['any'] == null || any.isEmpty || any.any((c) => conditionMatches(track, c));
  final allOk = r['all'] == null || all.every((c) => conditionMatches(track, c));
  return anyOk && allOk;
}

/// One-line plain-English description of a rule for the Settings panel.
String describeRule(Object? rule) {
  if (!isValidRule(rule)) return 'shows everything';
  final r = rule as Map;
  String part(Map c) {
    final field = c['field'].toString();
    if (field == 'bpm') {
      final min = c['min'], max = c['max'];
      if (min != null && max != null) return 'bpm between ${_numText(min)} and ${_numText(max)}';
      if (min != null) return 'bpm at least ${_numText(min)}';
      if (max != null) return 'bpm at most ${_numText(max)}';
      return 'bpm is ${_numText(c['equals'])}';
    }
    return c['equals'] != null ? '$field is "${c['equals']}"' : '$field contains "${c['contains']}"';
  }

  final bits = <String>[];
  final any = _conds(r, 'any');
  final all = _conds(r, 'all');
  if (any.isNotEmpty) bits.add(any.map(part).join(' or '));
  if (all.isNotEmpty) bits.add(all.map(part).join(' and '));
  return bits.join(', and ');
}
