import 'package:app/ui/chat/widgets/pane_question_card.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a TUI question reads without its frame, its choices apart', () {
    const screen = '''
╭──────────────────────────────────────────────╮
│ Do you want to run this command?              │
│   rm -rf build                                │
│                                               │
│ ❯ 1. Yes                                      │
│   2. Yes, and don't ask again                 │
│   3. No                                       │
╰──────────────────────────────────────────────╯
''';
    final lines = questionLines(screen);
    expect(lines.first, 'Do you want to run this command?');
    expect(questionChoices(lines), [
      ('1', 'Yes'),
      ('2', "Yes, and don't ask again"),
      ('3', 'No'),
    ]);
  });
}
