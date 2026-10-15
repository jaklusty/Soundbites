/// health.json: what has gone wrong lately, in the exact shape the Python wrote (events with
/// at/kind/ok/message/detail, capped at 40). The dashboard's Needs-attention strip reads this.
/// Best-effort: a failure to record never breaks the caller.
library;

import 'library.dart';
import 'store.dart';

const int maxEvents = 40;

Future<void> record(Store store, String kind, bool ok, String message, [String detail = '']) async {
  try {
    await store.update('health.json', <String, dynamic>{'events': <dynamic>[]}, (data) {
      final events = List<dynamic>.of(data['events'] is List ? data['events'] as List : const <dynamic>[]);
      final now = nowIso();
      events.add(<String, dynamic>{'at': now, 'kind': kind, 'ok': ok, 'message': message, 'detail': detail});
      final next = Json.of(data);
      next['events'] = events.length > maxEvents ? events.sublist(events.length - maxEvents) : events;
      next['updated'] = now;
      return next;
    });
  } catch (_) {
    /* best effort */
  }
}

/// Drop earlier events of one kind; used when that thing next succeeds.
Future<void> clearKind(Store store, String kind) async {
  try {
    await store.update('health.json', <String, dynamic>{'events': <dynamic>[]}, (data) {
      final events = data['events'] is List ? data['events'] as List : const <dynamic>[];
      final kept = events.where((e) => !(e is Map && e['kind'] == kind)).toList();
      if (kept.length == events.length) return null;
      final next = Json.of(data);
      next['events'] = kept;
      return next;
    });
  } catch (_) {
    /* best effort */
  }
}
