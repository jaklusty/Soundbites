/// Pure grouping and filtering of tracks for the library screen. Same sections as the original
/// dashboard, kept outside the widgets so they can be unit-tested.
library;

import '../engine/library.dart';
import '../engine/state.dart';
import '../engine/views.dart';

enum Filter { all, rising, peaking, favourite, clearable, pool, playable, noAudio }

class Section {
  Section(this.key, this.title, this.blurb, this.tracks);
  final String key, title, blurb;
  final List<Track> tracks;
}

String trendLine(Track t) {
  final h = t.usesHistory;
  if (h.length < 2) return '';
  final keys = h.keys.toList()..sort();
  final a = h[keys[keys.length - 2]]!;
  final b = h[keys[keys.length - 1]]!;
  if (a == 0 || b == 0 || a == b) return '';
  final pct = ((b - a) / a * 100).round();
  if (pct.abs() < 3) return '';
  return '${pct > 0 ? '▲' : '▼'} ${pct.abs()}% since last run';
}

bool matchesQuery(Track t, String q) {
  if (q.trim().isEmpty) return true;
  final hay = [t.title, t.artist, t.suits, t.notes, t.mood.join(' '), t.energy, t.platform, t.match?['title']?.toString(), t.match?['channel']?.toString()]
      .whereType<String>()
      .join(' ')
      .toLowerCase();
  return q.toLowerCase().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).every(hay.contains);
}

bool matchesFilter(Track t, Filter f, Set<String> favourites) {
  switch (f) {
    case Filter.all:
      return true;
    case Filter.rising:
      return t.direction == 'rising';
    case Filter.peaking:
      return t.direction == 'peaking';
    case Filter.favourite:
      return favourites.contains(t.id);
    case Filter.clearable:
      return t.licence == 'clearable';
    case Filter.pool:
      return t.pinned;
    case Filter.playable:
      return t.clipPresent;
    case Filter.noAudio:
      return !t.clipPresent;
  }
}

List<Track> visibleTracks(AppState s, {required String query, required Filter filter}) {
  final rule = s.activeView.isEmpty ? null : (s.savedViews[s.activeView] as Map?)?['rule'];
  return s.tracks.where((t) => ruleMatches(t, rule) && matchesQuery(t, query) && matchesFilter(t, filter, s.favourites)).toList();
}

List<Section> buildSections(AppState s, List<Track> list) {
  final lastRun = s.lastRun;
  final pool = list.where((t) => t.pinned).toList();
  final rest = list.where((t) => !t.pinned).toList();
  final thisRun = rest.where((t) => t.lastSeen == lastRun).toList();
  final older = rest.where((t) => t.lastSeen != lastRun).toList();
  final sections = [
    Section('fresh', 'Fresh — rising', 'Caught in the acceleration phase. Post within 48–72 hours or the reach advantage is gone.', thisRun.where((t) => t.direction == 'rising').toList()),
    Section('working', 'Still working', 'Seen this run, but peaking or already broad. Safe, less upside.', thisRun.where((t) => t.direction != 'rising').toList()),
    Section('kept', 'Kept — favourites', 'Starred in earlier runs, so their clips survive the retention sweep.', older.where((t) => s.favourites.contains(t.id)).toList()),
    Section('earlier', 'Earlier runs', 'Not in the latest run. Metadata kept; clips pruned unless starred.', older.where((t) => !s.favourites.contains(t.id)).toList()),
    Section('extras', 'Extras — always here', 'Not trend data. A standing set of genre suggestions, kept playable so there is always something to browse. Ignore freely.', pool),
  ];
  return sections.where((x) => x.tracks.isNotEmpty).toList();
}

({int tracked, int clips, int clipBytes, int fulls, int fullBytes}) storageSummary(List<Track> tracks) {
  var clips = 0, clipBytes = 0, fulls = 0, fullBytes = 0;
  for (final t in tracks) {
    if (t.clipPresent) {
      clips++;
      clipBytes += t.clipBytes ?? 480000;
    }
    if (t.full != null) {
      fulls++;
      fullBytes += t.fullBytes ?? 0;
    }
  }
  return (tracked: tracks.length, clips: clips, clipBytes: clipBytes, fulls: fulls, fullBytes: fullBytes);
}
