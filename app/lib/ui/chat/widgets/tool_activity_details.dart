import 'package:app/domain/session_state.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/chat/widgets/tool_content.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/core/widgets/copy_button.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Shared detail body for a single tool or an item inside a consecutive tool
/// run. It keeps commands, user input, stdout, stderr, and failures distinct so
/// raw protocol objects never become the primary reading experience.
class ToolActivityDetails extends StatelessWidget {
  const ToolActivityDetails({
    super.key,
    required this.tool,
    this.showHeader = false,
    this.resultMaxHeight,
  });

  final ToolEvent tool;
  final bool showHeader;
  final double? resultMaxHeight;

  @override
  Widget build(BuildContext context) {
    final content = ToolContent(tool);
    final output = content.output;
    final error = content.error;
    final input = content.inputText;
    final changes = content.changesText;
    final command = content.command;
    final hasCommand = content.isCommand && command != null;
    final hasResult = output.text?.trim().isNotEmpty ?? false;
    final hasStderr = output.stderr?.trim().isNotEmpty ?? false;
    final hasError = error != null;
    final commandResultIsDiff =
        hasCommand &&
        output.text != null &&
        _isGitDiffCommand(command) &&
        _looksLikeDiffBody(output.text!);

    return Column(
      key: ValueKey('tool-activity-${tool.toolCallId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showHeader) ...[
          _Header(content: content),
          const SizedBox(height: 14),
        ],
        if (changes != null) ...[
          _Section(
            key: const Key('tool-changes'),
            label: context.l10n.changes,
            body: changes,
            monospace: true,
            semanticDiff: true,
            maxHeight: resultMaxHeight,
            copyKey: ValueKey('tool-copy-${tool.toolCallId}-changes'),
          ),
        ] else if (hasCommand) ...[
          _Section(
            key: const Key('tool-command'),
            label: context.l10n.command,
            body: command,
            monospace: true,
            copyKey: ValueKey('tool-copy-${tool.toolCallId}-command'),
          ),
          if (content.workingDirectory case final cwd?) ...[
            const SizedBox(height: 8),
            _WorkingDirectory(path: cwd),
          ],
        ] else if (!content.isCommand && input != null) ...[
          _Section(
            key: const Key('tool-input'),
            label: content.inputLabel,
            body: input,
            monospace: !content.usesProseDetails,
            maxHeight: resultMaxHeight,
            copyKey: ValueKey('tool-copy-${tool.toolCallId}-input'),
          ),
        ],
        if (hasResult) ...[
          if (hasCommand ||
              changes != null ||
              (!content.isCommand && input != null))
            const SizedBox(height: 10),
          _Section(
            key: const Key('tool-result'),
            label: context.l10n.result,
            body: output.text!,
            monospace: !content.usesProseDetails,
            semanticDiff: commandResultIsDiff,
            maxHeight: resultMaxHeight,
            copyKey: ValueKey('tool-copy-${tool.toolCallId}-result'),
          ),
        ],
        if (hasStderr) ...[
          const SizedBox(height: 10),
          _Section(
            key: const Key('tool-stderr'),
            label: context.l10n.errorOutput,
            body: output.stderr!,
            monospace: true,
            maxHeight: resultMaxHeight,
            tone: _SectionTone.error,
            copyKey: ValueKey('tool-copy-${tool.toolCallId}-stderr'),
          ),
        ],
        if (hasError) ...[
          const SizedBox(height: 10),
          _Section(
            key: const Key('tool-error'),
            label: context.l10n.error,
            body: error,
            monospace: !content.usesProseDetails,
            maxHeight: resultMaxHeight,
            tone: _SectionTone.error,
            copyKey: ValueKey('tool-copy-${tool.toolCallId}-error'),
          ),
        ],
        if (tool.status == ToolEventStatus.completed &&
            changes == null &&
            !hasResult &&
            !hasStderr &&
            !hasError) ...[
          Text(
            context.l10n.completedWithoutOutput,
            style: context.typo.sansBody.copyWith(
              fontSize: 12.5,
              color: context.colors.muted,
            ),
          ),
        ],
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.content});

  final ToolContent content;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final status = content.tool.status;
    final statusColor = switch (status) {
      ToolEventStatus.failed => colors.error,
      ToolEventStatus.pending ||
      ToolEventStatus.running when content.awaitingApproval => colors.warning,
      ToolEventStatus.pending || ToolEventStatus.running => colors.working,
      ToolEventStatus.completed => colors.success,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                content.title,
                style: context.typo.title.copyWith(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                content.toolName,
                style: context.typo.monoSmall.copyWith(
                  fontSize: 11,
                  color: colors.muted,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: statusColor.withValues(alpha: .26)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                content.statusLabel,
                style: context.typo.sansBody.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: statusColor,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

enum _SectionTone { normal, error }

class _Section extends StatelessWidget {
  const _Section({
    super.key,
    required this.label,
    required this.body,
    required this.monospace,
    this.maxHeight,
    this.tone = _SectionTone.normal,
    this.semanticDiff = false,
    this.copyKey,
  });

  final String label;
  final String body;
  final bool monospace;
  final double? maxHeight;
  final _SectionTone tone;
  final bool semanticDiff;
  final Key? copyKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final foreground = tone == _SectionTone.error ? colors.error : colors.text;
    final textStyle = (monospace ? context.typo.mono : context.typo.sansBody)
        .copyWith(fontSize: 12, height: 1.48, color: foreground);
    final text = semanticDiff
        ? SelectableText.rich(
            TextSpan(style: textStyle, children: _diffLineSpans(body, context)),
          )
        : SelectableText(body, style: textStyle);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                label,
                style: context.typo.sansBody.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: tone == _SectionTone.error
                      ? colors.error
                      : colors.muted,
                ),
              ),
            ),
            if (body.trim().isNotEmpty)
              BayaCopyButton(
                key: copyKey,
                text: body,
                color: tone == _SectionTone.error ? colors.error : null,
              ),
          ],
        ),
        const SizedBox(height: 2),
        Container(
          width: double.infinity,
          color: Colors.transparent,
          child: BayaSurface(
            role: BayaSurfaceRole.content,
            radius: 13,
            elevated: false,
            emphasized: tone == _SectionTone.error,
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (maxHeight == null)
                  text
                else
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxHeight!),
                    child: SingleChildScrollView(child: text),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

enum _DiffLineKind { context, addition, deletion, metadata }

final _gitDiffCommandPattern = RegExp(
  r'(^|[\s;&|])git\s+(?:(?:-C|-c)\s+\S+\s+|--[^\s]+\s+)*diff(?:\s|$)',
  caseSensitive: false,
);

bool _isGitDiffCommand(String? command) {
  if (command == null) return false;
  return _gitDiffCommandPattern.hasMatch(command);
}

bool _looksLikeDiffBody(String body) {
  var hasPatchHeader = false;
  var hasAddition = false;
  var hasDeletion = false;
  for (final line in body.split('\n')) {
    if (line.startsWith('diff --git ') ||
        line.startsWith('@@') ||
        line.startsWith('--- ') ||
        line.startsWith('+++ ')) {
      hasPatchHeader = true;
    }
    if (line.startsWith('+') && !line.startsWith('+++')) {
      hasAddition = true;
    }
    if (line.startsWith('-') && !line.startsWith('---')) {
      hasDeletion = true;
    }
  }
  return hasPatchHeader || (hasAddition && hasDeletion);
}

List<TextSpan> _diffLineSpans(String body, BuildContext context) {
  final colors = context.colors;
  final lines = body.split('\n');
  return [
    for (var index = 0; index < lines.length; index++)
      _diffLineSpan(
        text: index == lines.length - 1 ? lines[index] : '${lines[index]}\n',
        kind: _diffLineKind(lines[index]),
        colors: colors,
      ),
  ];
}

TextSpan _diffLineSpan({
  required String text,
  required _DiffLineKind kind,
  required AppColors colors,
}) {
  final color = switch (kind) {
    _DiffLineKind.addition => colors.success,
    _DiffLineKind.deletion => colors.error,
    _DiffLineKind.metadata => colors.muted,
    _DiffLineKind.context => null,
  };
  return TextSpan(
    text: text,
    style: color == null ? null : TextStyle(color: color),
  );
}

_DiffLineKind _diffLineKind(String line) {
  if (line.startsWith('+++') || line.startsWith('---')) {
    return _DiffLineKind.metadata;
  }
  if (line.startsWith('+')) return _DiffLineKind.addition;
  if (line.startsWith('-')) return _DiffLineKind.deletion;
  if (line.startsWith('diff --git ') ||
      line.startsWith('index ') ||
      line.startsWith('@@') ||
      line.startsWith('new file mode ') ||
      line.startsWith('deleted file mode ') ||
      line.startsWith('old mode ') ||
      line.startsWith('new mode ') ||
      line.startsWith('similarity index ') ||
      line.startsWith('dissimilarity index ') ||
      line.startsWith('rename from ') ||
      line.startsWith('rename to ') ||
      line.startsWith('copy from ') ||
      line.startsWith('copy to ') ||
      line.startsWith('Binary files ') ||
      line.startsWith(r'\ No newline at end of file')) {
    return _DiffLineKind.metadata;
  }
  return _DiffLineKind.context;
}

class _WorkingDirectory extends StatelessWidget {
  const _WorkingDirectory({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      children: [
        Icon(LucideIcons.folder, size: 13, color: colors.muted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.typo.monoSmall.copyWith(
              fontSize: 11,
              color: colors.muted,
            ),
          ),
        ),
      ],
    );
  }
}
