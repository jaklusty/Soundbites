/// Zip handling for the tool downloads: Deno ships as a zip with a single executable inside.
/// Kept apart from `tools.dart` so the pure parts stay free of package:archive.
library;

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'tools.dart';

/// Stream the one entry `entry` of the zip at `zipPath` to `dest`, without reading the whole
/// archive into memory. Fails with a [ToolDownloadError] (code `zip`) when the entry is missing
/// or the file is not a zip.
Future<void> extractZipEntry(String zipPath, String entry, String dest) async {
  final input = InputFileStream(zipPath);
  try {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } catch (e) {
      throw ToolDownloadError('${p.basename(zipPath)} is not a zip file ($e)', ToolDownloadErrorCode.zip);
    }
    final file = archive.find(entry);
    if (file == null || !file.isFile) {
      throw ToolDownloadError('${p.basename(zipPath)} does not contain $entry', ToolDownloadErrorCode.zip);
    }
    final output = OutputFileStream(dest);
    try {
      file.writeContent(output);
    } finally {
      await output.close();
    }
  } finally {
    await input.close();
  }
}
