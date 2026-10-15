/// Opening a library folder (hard requirement 2). Three outcomes:
///   - it has a library.json: open it;
///   - it exists but has no library.json: the caller must ask "Start a new library here?" and then
///     call createLibrary();
///   - the remembered folder is missing (an unplugged drive): a clear message, and never a new
///     empty library.
/// Plus the cross-platform warnings: cloud-synced locations and very long paths.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'library.dart';
import 'store.dart';

sealed class LibraryProbe {
  const LibraryProbe();

  /// 'ok' | 'empty' | 'missing' | 'not-a-folder'
  String get status;
}

class ProbeOk extends LibraryProbe {
  const ProbeOk(this.warnings);
  final List<String> warnings;
  @override
  String get status => 'ok';
}

class ProbeEmpty extends LibraryProbe {
  const ProbeEmpty(this.warnings);
  final List<String> warnings;
  @override
  String get status => 'empty';
}

class ProbeMissing extends LibraryProbe {
  const ProbeMissing();
  @override
  String get status => 'missing';
}

class ProbeNotAFolder extends LibraryProbe {
  const ProbeNotAFolder();
  @override
  String get status => 'not-a-folder';
}

Future<LibraryProbe> probeLibrary(String path) async {
  final type = await FileSystemEntity.type(path);
  if (type == FileSystemEntityType.notFound) return const ProbeMissing();
  if (type != FileSystemEntityType.directory) return const ProbeNotAFolder();
  final warnings = pathWarnings(path);
  final lib = await FileSystemEntity.type(p.join(path, 'library.json'));
  return lib == FileSystemEntityType.notFound ? ProbeEmpty(warnings) : ProbeOk(warnings);
}

/// The neutral default profile for a new library: keep_runs 8, wav16, the three saved views with real display rules.
Json defaultProfile() => <String, dynamic>{
      'views': <String, dynamic>{
        'note': 'Saved views only change what the dashboard shows. They never affect what is captured.',
        'active': '',
        'saved': <String, dynamic>{
          'instrumental': <String, dynamic>{
            'label': 'Instrumental / voiceover-safe',
            'description': 'Low-vocal tracks, for when a voice has to sit on top.',
            'rule': <String, dynamic>{
              'any': <dynamic>[
                <String, dynamic>{'field': 'mood', 'contains': 'instrumental'},
                <String, dynamic>{'field': 'mood', 'contains': 'ambient'},
                <String, dynamic>{'field': 'suits', 'contains': 'no vocal'},
                <String, dynamic>{'field': 'suits', 'contains': 'instrumental'},
              ],
            },
          },
          'high-energy': <String, dynamic>{
            'label': 'High energy',
            'description': 'Fast, loud, hard transients.',
            'rule': <String, dynamic>{
              'any': <dynamic>[
                <String, dynamic>{'field': 'energy', 'equals': 'high'},
              ],
            },
          },
          'low-energy': <String, dynamic>{
            'label': 'Low energy',
            'description': 'Slower, quieter, more space.',
            'rule': <String, dynamic>{
              'any': <dynamic>[
                <String, dynamic>{'field': 'energy', 'equals': 'low'},
              ],
            },
          },
        },
      },
      'retention': <String, dynamic>{
        'keep_runs': 8,
        'note': 'Clips kept for pinned tracks, favourites, and the last N runs.',
      },
      'promote': <String, dynamic>{
        'format': 'wav16',
        'note': 'Format for full tracks pulled when you star something: wav16, wav24 or mp3.',
      },
    };

/// Create the state files for a brand-new library in an existing, empty-of-library folder.
/// Throws a [StateError] when a library.json is already there.
Future<void> createLibrary(String path) async {
  final store = Store(path);
  await Directory(p.join(path, 'clips')).create(recursive: true);
  await Directory(p.join(path, 'full')).create(recursive: true);
  await Directory(p.join(path, 'pending')).create(recursive: true);
  await store.withLock(() async {
    final existing = await store.read('library.json');
    if (existing.data != null) throw StateError('A library already exists here');
    await store.writeUnlocked('library.json', Library.empty().json);
    await store.writeUnlocked('favourites.json', Favourites.empty().json);
    await store.writeUnlocked('profile.json', defaultProfile());
  });
}

String _homeDir() {
  final env = Platform.environment;
  return env['HOME'] ?? env['USERPROFILE'] ?? '';
}

/// Warnings about where the folder is. Heuristics; each is one plain sentence for the UI.
///
/// `platform` is a Dart `Platform.operatingSystem` name ('macos', 'windows', 'linux'); the Node
/// names 'darwin' and 'win32' are accepted too. Paths are read with that platform's separator.
List<String> pathWarnings(String path, {String? home, String? platform}) {
  final os = platform ?? Platform.operatingSystem;
  final isWin = os == 'windows' || os == 'win32';
  final isMac = os == 'macos' || os == 'darwin';
  final ctx = isWin ? p.windows : p.posix;
  final sep = ctx.separator;
  final homeDir = home ?? _homeDir();
  final resolved = ctx.normalize(ctx.absolute(path));
  final lower = resolved.toLowerCase();
  bool under(String base) => lower == base.toLowerCase() || lower.startsWith('${base.toLowerCase()}$sep');
  final warnings = <String>[];

  final synced = lower.contains('${sep}onedrive') ||
      lower.contains('${sep}mobile documents$sep') ||
      lower.contains('${sep}icloud drive') ||
      lower.contains('${sep}dropbox') ||
      lower.contains('${sep}google drive') ||
      (isMac && (under(ctx.join(homeDir, 'Desktop')) || under(ctx.join(homeDir, 'Documents'))));
  if (synced) {
    warnings.add(
      isWin
          ? 'This folder looks cloud-synced (OneDrive or similar). Synced folders can offload files, and DaVinci Resolve then loses the media mid-edit. The Videos or Music folder is a safer place.'
          : 'This folder may be synced by iCloud (Desktop and Documents often are). Synced folders can offload files, and DaVinci Resolve then loses the media mid-edit. The Movies folder is a safer place.',
    );
  }
  // Windows limits full paths to 260 characters unless long paths are enabled. full/<id>/<id>.source.webm can add ~140.
  if (resolved.length > 110) {
    warnings.add(
      "This folder's path is ${resolved.length} characters long. Files inside it may exceed Windows' 260-character limit; a shorter path is safer.",
    );
  }
  return warnings;
}
