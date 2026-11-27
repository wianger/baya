import 'dart:convert';

import 'package:app/ui/terminals/terminal_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a program\'s screen modes are read from its bytes, even split', () {
    final modes = ScreenModes()
      ..feed(utf8.encode('\x1b[?1000l\x1b[?1049h\x1b[?10'));
    expect(modes.alt, isTrue);
    expect(modes.mouse, isFalse);
    modes.feed(utf8.encode('03h\x1b[?1006h'));
    expect(modes.mouse, isTrue);
    expect(modes.sgr, isTrue);
    modes.feed(utf8.encode('\x1b[?1049l'));
    expect(modes.alt, isFalse);
  });
}
