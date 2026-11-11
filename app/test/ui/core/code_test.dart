import 'package:app/ui/core/code/code_view.dart';
import 'package:app/ui/core/code/highlighter.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/code/line_diff.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('languages come from fences and file names', () {
    expect(CodeHighlighter.resolve('ts'), 'typescript');
    expect(CodeHighlighter.resolve('Python'), 'python');
    expect(CodeHighlighter.resolve('nonsense'), isNull);
    expect(CodeHighlighter.languageForPath('lib/main.dart'), 'dart');
    expect(
      CodeHighlighter.languageForPath(r'C:\code\Dockerfile'),
      'dockerfile',
    );
    expect(CodeHighlighter.languageForPath('README'), isNull);
  });

  test('known code is split into coloured spans; unknown stays plain', () {
    const style = TextStyle(fontSize: 12);
    final dart = CodeHighlighter.highlight(
      'final x = 1; // one',
      language: 'dart',
      style: style,
      brightness: Brightness.dark,
    );
    final spans = <TextSpan>[];
    dart.visitChildren((span) {
      if (span is TextSpan && span.text != null) spans.add(span);
      return true;
    });
    expect(spans.map((s) => s.text).join(), 'final x = 1; // one');
    expect(
      spans.where((s) => s.style?.color != null).map((s) => s.text),
      containsAll(['final', '1', '// one']),
    );
    final plain = CodeHighlighter.highlight(
      'hello',
      language: null,
      style: style,
      brightness: Brightness.light,
    );
    expect(plain.text, 'hello');
  });

  test(
    'a diff the computer trimmed numbers its lines from where it starts',
    () {
      final hunks = lineDiff('a\nb\nc', 'a\nB\nc', firstLine: 120);
      final changed = hunks.single.where((l) => l.kind != DiffKind.context);
      expect([for (final l in changed) l.oldNumber ?? l.newNumber], [121, 121]);
      expect(hunks.single.first.newNumber, 120);
    },
  );

  test('the line diff finds the changed lines and keeps context', () {
    final old = [for (var i = 1; i <= 20; i++) 'line $i'].join('\n');
    final next = old
        .replaceFirst('line 3\n', 'line three\n')
        .replaceFirst('line 17\n', '');
    final hunks = lineDiff(old, next);
    expect(hunks, hasLength(2));
    expect(diffStats(hunks), (added: 1, removed: 2));
    final first = hunks.first;
    expect(first.first.text, 'line 1');
    expect(first.where((l) => l.kind == DiffKind.added).single.newNumber, 3);
    expect(
      lineDiff(null, 'a\nb').single.every((l) => l.kind == DiffKind.added),
      isTrue,
    );
  });

  testWidgets('a diff shows every changed and context line', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: const Scaffold(
          body: DiffView(
            path: 'src/auth/login.ts',
            oldText: 'await signIn(form)\nrouter.push(next)',
            newText:
                'await signIn(form)\nawait session.ready()\nrouter.push(next)',
          ),
        ),
      ),
    );
    expect(
      find.textContaining('router.push', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('session.ready', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('3'), findsOneWidget);
  });
}
