import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundbites/version.dart';

void main() {
  test('lib/version.dart matches pubspec.yaml', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    expect(line.split(' ')[1].split('+').first, appVersion);
  });
}
