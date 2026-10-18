import 'dart:io';

/// A plain text log in the app-data folder, so a problem on someone else's computer can be read
/// after the fact. Lines carry a UTC timestamp. When the file passes [maxBytes] it is renamed to
/// `<name>.1` and a fresh one started, so it never grows without bound.
class FileLog {
  FileLog(this.path, {this.maxBytes = 2 * 1024 * 1024});
  final String path;
  final int maxBytes;
  IOSink? _sink;
  int _written = 0;

  void call(String line) {
    try {
      _sink ??= _open();
      final stamp = DateTime.now().toUtc().toIso8601String().substring(0, 19);
      final text = '$stamp  $line\n';
      _sink!.write(text);
      _written += text.length;
      if (_written > maxBytes) _rotate();
    } catch (_) {
      // Logging must never take the app down.
    }
  }

  IOSink _open() {
    final f = File(path);
    f.parent.createSync(recursive: true);
    _written = f.existsSync() ? f.lengthSync() : 0;
    return f.openWrite(mode: FileMode.append);
  }

  void _rotate() {
    _sink?.close();
    _sink = null;
    try {
      File(path).renameSync('$path.1');
    } catch (_) {}
    _written = 0;
  }

  Future<void> close() async {
    await _sink?.close();
    _sink = null;
  }
}
