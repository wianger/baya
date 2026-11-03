import 'package:app/domain/session_state.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/chat/widgets/tool_content.dart';
import 'package:app/ui/core/code/code_view.dart';
import 'package:app/ui/core/code/highlighter.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/copy_button.dart';
import 'package:flutter/material.dart';

/// What a tool call did, shown the way its kind reads best: an edit as a
/// highlighted diff, a read as the file's lines, a command as a terminal, and
/// anything else as its input and result.
class ToolActivityDetails extends StatelessWidget {
  const ToolActivityDetails({super.key, required this.tool});

  final ToolEvent tool;

  @override
  Widget build(BuildContext context) {
    final content = ToolContent(tool);
    final output = content.output;
    final error = content.error;
    final fields = content.inputFields;
    final diffs = content.diffs;
    final command = content.isCommand ? content.command : null;
    final result = output.text?.trim().isNotEmpty == true ? output.text! : null;
    final stderr = output.stderr?.trim().isNotEmpty == true
        ? output.stderr!
        : null;
    final path = content.path;
    final children = <Widget>[
      if (diffs.isNotEmpty)
        for (final diff in diffs)
          DiffView(
            key: const Key('tool-changes'),
            path: diff.path,
            oldText: diff.oldText,
            newText: diff.newText,
          )
      else if (command != null)
        _Terminal(
          key: const Key('tool-command'),
          command: command,
          workingDirectory: content.workingDirectory,
          output: result,
          exitLabel: content.exitLabel,
          clean: content.exitedCleanly,
        )
      else ...[
        if (fields.isNotEmpty)
          _InputFields(key: const Key('tool-input'), fields: fields),
        if (result != null)
          content.isRead && path != null
              ? CodeBlock(
                  key: const Key('tool-result'),
                  code: result,
                  language: CodeHighlighter.languageForPath(path),
                  title: path,
                  lineNumbers: true,
                  firstLine: content.firstLine ?? 1,
                  foldAfter: 16,
                )
              : content.usesProseDetails
              ? SelectableText(
                  result,
                  key: const Key('tool-result'),
                  style: context.typo.sansBody.copyWith(
                    fontSize: 13.5,
                    height: 1.5,
                    color: context.colors.muted2,
                  ),
                )
              : CodeBlock(
                  key: const Key('tool-result'),
                  code: result,
                  language: _looksLikeDiff(result) ? 'diff' : null,
                  header: false,
                  foldAfter: 16,
                ),
      ],
      if (stderr != null)
        _Problem(
          key: const Key('tool-stderr'),
          label: context.l10n.errorOutput,
          text: stderr,
        ),
      if (error != null)
        _Problem(
          key: const Key('tool-error'),
          label: context.l10n.error,
          text: error,
        ),
      if (tool.status == ToolEventStatus.completed &&
          diffs.isEmpty &&
          command == null &&
          result == null &&
          stderr == null &&
          error == null)
        Text(
          context.l10n.completedWithoutOutput,
          style: context.typo.sansBody.copyWith(
            fontSize: 12.5,
            color: context.colors.muted,
          ),
        ),
    ];
    return Column(
      key: ValueKey('tool-activity-${tool.toolCallId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          children[i],
        ],
      ],
    );
  }

  static bool _looksLikeDiff(String text) {
    var header = false;
    var plus = false;
    var minus = false;
    for (final line in text.split('\n')) {
      if (line.startsWith('diff --git ') || line.startsWith('@@')) {
        header = true;
      }
      if (line.startsWith('+') && !line.startsWith('+++')) plus = true;
      if (line.startsWith('-') && !line.startsWith('---')) minus = true;
    }
    return header || (plus && minus);
  }
}

/// A shell command as a terminal shows it: the prompt line, its output and
/// how it ended.
class _Terminal extends StatelessWidget {
  const _Terminal({
    super.key,
    required this.command,
    required this.workingDirectory,
    required this.output,
    required this.exitLabel,
    required this.clean,
  });

  final String command;
  final String? workingDirectory;
  final String? output;
  final String? exitLabel;
  final bool clean;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = codeTextStyle(context, size: 12).copyWith(color: colors.text);
    return Container(
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
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    workingDirectory ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.monoSmall.copyWith(
                      fontSize: 11,
                      color: colors.muted,
                    ),
                  ),
                ),
                if (exitLabel case final label?)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: (clean ? colors.success : colors.error).withValues(
                        alpha: .12,
                      ),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      label,
                      style: context.typo.monoSmall.copyWith(
                        fontSize: 10.5,
                        color: clean ? colors.success : colors.error,
                      ),
                    ),
                  ),
                BayaCopyButton(text: command),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 14, 10),
            child: SelectableText.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: r'$ ',
                    style: style.copyWith(color: colors.accent),
                  ),
                  context.highlightCode(command, 'bash', style),
                ],
              ),
            ),
          ),
          if (output != null) ...[
            Divider(height: 1, color: colors.border.withValues(alpha: .7)),
            CodeBlock(code: output!, header: false, foldAfter: 14, bare: true),
          ],
        ],
      ),
    );
  }
}

/// Error output or a failure, set apart in the error colour.
class _Problem extends StatelessWidget {
  const _Problem({super.key, required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: colors.error.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: context.typo.sansBody.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: colors.error,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            text,
            style: codeTextStyle(
              context,
              size: 12,
            ).copyWith(color: colors.error),
          ),
        ],
      ),
    );
  }
}

/// A call's input: short values as label–value lines, long ones as blocks.
class _InputFields extends StatelessWidget {
  const _InputFields({super.key, required this.fields});

  final List<({String label, String value})> fields;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final short = [
      for (final field in fields)
        if (field.value.length <= 90 && !field.value.contains('\n')) field,
    ];
    final long = [
      for (final field in fields)
        if (!short.contains(field)) field,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final field in short)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 92,
                  child: Text(
                    field.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.sansBody.copyWith(
                      fontSize: 12,
                      color: colors.muted,
                    ),
                  ),
                ),
                Expanded(
                  child: SelectableText(
                    field.value,
                    style: context.typo.mono.copyWith(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        for (final field in long) ...[
          const SizedBox(height: 4),
          CodeBlock(code: field.value, title: field.label, foldAfter: 12),
        ],
      ],
    );
  }
}
