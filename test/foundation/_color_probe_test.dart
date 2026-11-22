import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String hex(Color c) =>
    '#${(c.r * 255).round().toRadixString(16).padLeft(2, '0')}'
    '${(c.g * 255).round().toRadixString(16).padLeft(2, '0')}'
    '${(c.b * 255).round().toRadixString(16).padLeft(2, '0')}';

void main() {
  test('seed colors', () {
    for (final seed in const [Color(0xFF1B8CF5), Color(0xFF6750A4)]) {
      final s = ColorScheme.fromSeed(seedColor: seed);
      debugPrint('seed=${hex(seed)} surface=${hex(s.surface)} '
          'surfaceContainer=${hex(s.surfaceContainer)} '
          'onSurface=${hex(s.onSurface)} '
          'surfaceContainerHighest=${hex(s.surfaceContainerHighest)}');
    }
  });
}
