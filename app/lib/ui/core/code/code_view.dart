import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/code/highlighter.dart';
import 'package:app/ui/core/code/line_diff.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/copy_button.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Highlighted code with an optional title bar, line numbers and a fold for
/// long text. Scrolls sideways rather than wrapping, as editors do.
class CodeBlock extends StatefulWidget {
  const CodeBlock({
    super.key,
    required this.code,
    this.language,
    this.title,
    this.lineNumbers = false,
    this.firstLine = 1,
    this.foldAfter,
    this.header = true,
    this.bare = false,
  });

  final String code;

  /// Without its own background and border, inside another block.
  final bool bare;

  /// A fence name or registered language; unknown ones show plain.
  final String? language;

  /// Shown in the title bar instead of the language (a file name, say).
  final String? title;
  final bool lineNumbers;
  final int firstLine;

  /// Lines shown before "Show all"; null shows everything.
  final int? foldAfter;
  final bool header;

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  bool _unfolded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final code = widget.code.endsWith('\n')
        ? widget.code.substring(0, widget.code.length - 1)
        : widget.code;
    final lines = '\n'.allMatches(code).length + 1;
    final fold = widget.foldAfter;
    final folded = !_unfolded && fold != null && lines > fold + 2;
    final shown = folded ? code.split('\n').take(fold).join('\n') : code;
    final style = codeTextStyle(context).copyWith(color: colors.text);
    final label =
        widget.title ??
        (widget.language?.isNotEmpty == true ? widget.language! : null);
    return Container(
      width: double.infinity,
      decoration: widget.bare
          ? null
          : BoxDecoration(
              color: colors.codeBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.border.withValues(alpha: .7)),
            ),
      clipBehavior: widget.bare ? Clip.none : Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.header)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.typo.monoSmall.copyWith(
                        fontSize: 11,
                        color: colors.muted,
                      ),
                    ),
                  ),
                  BayaCopyButton(
                    key: const Key('code-copy'),
                    text: widget.code,
                  ),
                ],
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.fromLTRB(
              widget.lineNumbers ? 8 : 12,
              widget.header ? 2 : 10,
              14,
              folded ? 4 : 12,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.lineNumbers)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Text(
                      [
                        for (
                          var i = 0;
                          i < '\n'.allMatches(shown).length + 1;
                          i++
                        )
                          '${widget.firstLine + i}',
                      ].join('\n'),
                      textAlign: TextAlign.right,
                      style: style.copyWith(
                        color: colors.muted.withValues(alpha: .7),
                      ),
                    ),
                  ),
                HighlightedCode(
                  code: shown,
                  language: widget.language,
                  style: style,
                ),
              ],
            ),
          ),
          if (folded)
            InkWell(
              onTap: () => setState(() => _unfolded = true),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                child: Text(
                  context.l10n.showAllLines(lines),
                  style: context.typo.sansBody.copyWith(
                    fontSize: 12,
                    color: colors.muted2,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One file's change: its path and line counts, then the changed lines with
/// their numbers, highlighted in the file's language.
class DiffView extends StatelessWidget {
  const DiffView({
    super.key,
    required this.path,
    required this.oldText,
    required this.newText,
    this.firstLine = 1,
  });

  final String path;
  final String? oldText;
  final String newText;
  final int firstLine;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final hunks = lineDiff(oldText, newText, firstLine: firstLine);
    final stats = diffStats(hunks);
    final language = CodeHighlighter.languageForPath(path);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.codeBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border.withValues(alpha: .7)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 2),
            child: Row(
              children: [
                Icon(LucideIcons.fileCode, size: 14, color: colors.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.monoSmall.copyWith(
                      fontSize: 11.5,
                      color: colors.muted2,
                    ),
                  ),
                ),
                Text(
                  '+${stats.added} ',
                  style: context.typo.monoSmall.copyWith(
                    fontSize: 11.5,
                    color: colors.success,
                  ),
                ),
                Text(
                  '−${stats.removed}',
                  style: context.typo.monoSmall.copyWith(
                    fontSize: 11.5,
                    color: colors.error,
                  ),
                ),
                BayaCopyButton(text: newText),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: HunkLines(hunks: hunks, language: language),
          ),
        ],
      ),
    );
  }
}

/// Diff hunks as numbered lines, added and removed ones tinted, highlighted
/// in [language]; separate hunks are divided by a gap. Scrolls sideways.
class HunkLines extends StatelessWidget {
  const HunkLines({super.key, required this.hunks, required this.language});

  final List<DiffHunk> hunks;
  final String? language;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = codeTextStyle(context, size: 12).copyWith(color: colors.text);
    final numberStyle = style.copyWith(
      color: colors.muted.withValues(alpha: .75),
    );
    var widest = 1;
    for (final hunk in hunks) {
      for (final line in hunk) {
        final n = line.newNumber ?? line.oldNumber ?? 0;
        if (n > widest) widest = n;
      }
    }
    final width = '$widest'.length * 7.6 + 4;
    final rows = <Widget>[];
    for (var h = 0; h < hunks.length; h++) {
      if (h > 0) {
        rows.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text('  ⋯', style: numberStyle),
          ),
        );
      }
      for (final line in hunks[h]) {
        final (tint, sign) = switch (line.kind) {
          DiffKind.added => (colors.success.withValues(alpha: .13), '+'),
          DiffKind.removed => (colors.error.withValues(alpha: .13), '−'),
          DiffKind.context => (Colors.transparent, ' '),
        };
        rows.add(
          ColoredBox(
            color: tint,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: width,
                  child: Text(
                    '${line.newNumber ?? line.oldNumber}',
                    textAlign: TextAlign.right,
                    style: numberStyle,
                  ),
                ),
                SizedBox(
                  width: 18,
                  child: Text(
                    sign,
                    textAlign: TextAlign.center,
                    style: style.copyWith(
                      color: switch (line.kind) {
                        DiffKind.added => colors.success,
                        DiffKind.removed => colors.error,
                        DiffKind.context => colors.muted,
                      },
                    ),
                  ),
                ),
                Text.rich(context.highlightCode(line.text, language, style)),
                const SizedBox(width: 14),
              ],
            ),
          ),
        );
      }
    }
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: IntrinsicWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rows,
            ),
          ),
        ),
      ),
    );
  }
}

/// Selectable code in colour. Long code shows plain for the moment it takes a
/// background isolate to colour it; results are cached.
class HighlightedCode extends StatefulWidget {
  const HighlightedCode({
    super.key,
    required this.code,
    required this.language,
    required this.style,
  });

  final String code;
  final String? language;
  final TextStyle style;

  @override
  State<HighlightedCode> createState() => _HighlightedCodeState();
}

class _HighlightedCodeState extends State<HighlightedCode> {
  List<Token>? _tokens;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(HighlightedCode old) {
    super.didUpdateWidget(old);
    if (old.code != widget.code || old.language != widget.language) _load();
  }

  void _load() {
    final language = CodeHighlighter.resolve(widget.language);
    _tokens = CodeHighlighter.cachedTokens(widget.code, language);
    if (_tokens != null || language == null) return;
    final code = widget.code;
    CodeHighlighter.tokensLater(code, language).then((tokens) {
      if (mounted && widget.code == code) setState(() => _tokens = tokens);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = _tokens;
    return SelectableText.rich(
      tokens == null
          ? TextSpan(text: widget.code, style: widget.style)
          : CodeHighlighter.spans(
              tokens,
              widget.style,
              Theme.of(context).brightness,
            ),
    );
  }
}

/// [tokens] cut into lines, each line its own runs.
List<List<Token>> tokenLines(List<Token> tokens) {
  final lines = <List<Token>>[[]];
  for (final (text, scope) in tokens) {
    final parts = text.split('\n');
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) lines.add([]);
      if (parts[i].isNotEmpty) lines.last.add((parts[i], scope));
    }
  }
  return lines;
}
