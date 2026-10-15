/// Track ids. A byte-for-byte port of `slugify` in the original ingest.py (hard requirement 10).
/// favourites.json, `clips/<id>.mp3` and `full/<id>/` are all keyed on this, so any drift would orphan
/// every favourite and clip.
///
/// The Python:
///   readable_part(s): NFKD → drop non-ASCII → lower() → strip [^\w\s-] → [\s_-]+ → "-" → strip("-")
///   identity(s):      NFKC → casefold() → strip [^\w\s] (Unicode \w) → collapse \s+ → strip; or raw if empty
///   id = (readable(artist)-readable(title))[:50] + "-" + sha1(identity(artist) NUL identity(title))[:8]
///        or "track-" + hash when the readable part is empty.
///
/// Where Dart's defaults differ from Python's and are corrected here:
///   - casefold: Dart has no casefold, and its `toLowerCase` tables lag Python's Unicode version;
///     per-code-point toLowerCase plus a generated table of every code point where Python folds
///     differently (ß→ss, ς→σ, İ, Georgian Mtavruli, Adlam, ligatures, ...). See casefold_table.dart.
///   - \s: Python's includes \x1c-\x1f and \x85, and excludes ﻿; the Python set is spelled out
///     explicitly (`pySpaceClass`) instead of using Dart's \s.
///   - \w: Python's is "alphanumeric or _" in its Unicode database; here it is \p{L}\p{N}_. These
///     agree except for characters added in Unicode versions newer than the Python's. None of
///     those occur in real titles; the oracle test covers every script that does.
///   - normalisation: package:unorm_dart (Unicode 18 data) rather than the Python's 15.1; the
///     difference is only characters that were unassigned in 15.1.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'casefold_table.dart';

/// Parsed lazily from the generated table.
final Map<int, String> _foldTable = _parseFoldTable();

Map<int, String> _parseFoldTable() {
  final out = <int, String>{};
  for (final entry in casefoldExceptions.split(';')) {
    final parts = entry.split(':');
    final cp = int.parse(parts[0], radix: 16);
    final folded = parts[1].split(',').map((h) => int.parse(h, radix: 16)).toList();
    out[cp] = String.fromCharCodes(folded);
  }
  return out;
}

/// Python's str.casefold(), code point by code point (Python's casefold is not context-sensitive,
/// unlike `toLowerCase` on a whole string, which would turn a final Σ into ς).
String casefold(String s) {
  final out = StringBuffer();
  for (final cp in s.runes) {
    final mapped = _foldTable[cp];
    if (mapped != null) {
      out.write(mapped);
    } else {
      out.write(String.fromCharCode(cp).toLowerCase());
    }
  }
  return out.toString();
}

// Python's str.isspace() set, which is what its regex \s and str.strip() use.
final RegExp _pySpaceRun = RegExp('[$pySpaceClass]+', unicode: true);
final RegExp _pyStrip = RegExp('^[$pySpaceClass]+|[$pySpaceClass]+\$', unicode: true);
// Unicode \w per Python: letters, numbers, underscore.
final RegExp _notWordOrSpace = RegExp('[^\\p{L}\\p{N}_$pySpaceClass]', unicode: true);
// After ASCII folding only ASCII remains, so these are the ASCII subsets.
final RegExp _asciiNotWordSpaceDash = RegExp(r'[^A-Za-z0-9_\t\n\x0b\x0c\r\x1c-\x1f -]');
final RegExp _asciiSepRun = RegExp(r'[\t\n\x0b\x0c\r\x1c-\x1f _-]+');
final RegExp _nonAscii = RegExp(r'[^\x00-\x7f]');
final RegExp _dashEnds = RegExp(r'^-+|-+$');

String _readablePart(String s) {
  // NFKD then drop everything outside ASCII (Python: encode("ascii", "ignore")).
  final ascii = unorm.nfkd(s).replaceAll(_nonAscii, '');
  final lowered = ascii.toLowerCase();
  final cleaned = lowered.replaceAll(_asciiNotWordSpaceDash, '');
  return cleaned.replaceAll(_asciiSepRun, '-').replaceAll(_dashEnds, '');
}

String _identity(String s) {
  final raw = casefold(unorm.nfkc(s));
  final cleaned = raw.replaceAll(_notWordOrSpace, '').replaceAll(_pySpaceRun, ' ').replaceAll(_pyStrip, '');
  // An emoji-only title cleans to nothing; fall back to the raw form so such titles stay distinct.
  return cleaned.isNotEmpty ? cleaned : raw.replaceAll(_pyStrip, '');
}

/// The track id for an artist/title pair, exactly as ingest.py computed it.
String slugify(String? artist, String? title) {
  final a = artist ?? '';
  final t = title ?? '';
  var readable = [_readablePart(a), _readablePart(t)].where((p) => p.isNotEmpty).join('-');
  if (readable.length > 50) readable = readable.substring(0, 50);
  final digest = sha1.convert(utf8.encode('${_identity(a)}\x00${_identity(t)}')).toString().substring(0, 8);
  return readable.isNotEmpty ? '$readable-$digest' : 'track-$digest';
}
