import 'package:flutter_test/flutter_test.dart';
import 'package:soundbites/engine/library.dart';
import 'package:soundbites/engine/state.dart';
import 'package:soundbites/ui/format.dart';
import 'package:soundbites/ui/sections.dart';

Track t(Map<String, dynamic> m) => Track({'id': m['id'] ?? 'x', 'first_seen': '2026-01-01', 'runs': <String>[], 'clip': null, 'clip_present': false, ...m});

void main() {
  test('sections follow the original dashboard rules', () {
    final tracks = [
      t({'id': 'a', 'title': 'A', 'direction': 'rising', 'last_seen': '2026-10-05'}),
      t({'id': 'b', 'title': 'B', 'direction': 'peaking', 'last_seen': '2026-10-05'}),
      t({'id': 'c', 'title': 'C', 'direction': 'rising', 'last_seen': '2026-09-20'}),
      t({'id': 'd', 'title': 'D', 'direction': 'rising', 'last_seen': '2026-09-20'}),
      t({'id': 'e', 'title': 'E', 'direction': 'extra', 'last_seen': '2026-10-05', 'pinned': true}),
    ];
    final s = AppState(version: 'x', library: LibraryState.none, tracks: tracks, lastRun: '2026-10-05', favourites: {'c'});
    final secs = buildSections(s, visibleTracks(s, query: '', filter: Filter.all));
    expect(secs.map((x) => '${x.key}:${x.tracks.map((y) => y.id).join()}').toList(), ['fresh:a', 'working:b', 'kept:c', 'earlier:d', 'extras:e']);
  });

  test('search and filters', () {
    final tracks = [
      t({'id': 'a', 'title': 'Glue', 'artist': 'Bicep', 'mood': ['breakbeat'], 'direction': 'rising', 'clip_present': true, 'licence': 'clearable'}),
      t({'id': 'b', 'title': 'Other', 'artist': 'X', 'direction': 'peaking'}),
    ];
    final s = AppState(version: 'x', library: LibraryState.none, tracks: tracks, favourites: {'b'});
    expect(visibleTracks(s, query: 'bicep', filter: Filter.all).map((x) => x.id), ['a']);
    expect(visibleTracks(s, query: 'break', filter: Filter.all).map((x) => x.id), ['a']);
    expect(visibleTracks(s, query: '', filter: Filter.favourite).map((x) => x.id), ['b']);
    expect(visibleTracks(s, query: '', filter: Filter.clearable).map((x) => x.id), ['a']);
    expect(visibleTracks(s, query: '', filter: Filter.noAudio).map((x) => x.id), ['b']);
  });

  test('saved view limits what is shown', () {
    final tracks = [t({'id': 'a', 'energy': 'high'}), t({'id': 'b', 'energy': 'low'})];
    final s = AppState(version: 'x', library: LibraryState.none, tracks: tracks, activeView: 'hi', profile: {
      'views': {'saved': {'hi': {'label': 'High', 'rule': {'any': [{'field': 'energy', 'equals': 'high'}]}}}}
    });
    expect(visibleTracks(s, query: '', filter: Filter.all).map((x) => x.id), ['a']);
  });

  test('formatting', () {
    expect(fmtUses(142000), '142k uses');
    expect(fmtUses(1500000), '1.5m uses');
    expect(fmtTime(273.8), '4:34');
    expect(fmtMb(481114), '481 KB');
    expect(fmtMb(35e6), '35 MB');
    expect(trendLine(t({'uses_history': {'2026-09-01': 100, '2026-09-10': 150}})), '▲ 50% since last run');
    expect(trendLine(t({'uses_history': {'2026-09-01': 100, '2026-09-10': 101}})), '');
    expect(storageSummary([t({'clip_present': true, 'clip_bytes': 10, 'full': 'x', 'full_bytes': 5}), t({})]), (tracked: 2, clips: 1, clipBytes: 10, fulls: 1, fullBytes: 5));
  });
}
