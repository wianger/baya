import 'package:app/acp/acp.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// An agent asks for input (ACP `elicitation/create`): a small form, or a
/// link to open. Sits above the composer until any phone answers.
class ElicitationCard extends StatefulWidget {
  const ElicitationCard({
    super.key,
    required this.request,
    required this.onAnswer,
  });

  final ElicitationRequest request;

  /// `accept` (with the values), `decline` or `cancel`.
  final void Function(String action, [Map<String, dynamic>? content]) onAnswer;

  @override
  State<ElicitationCard> createState() => _ElicitationCardState();
}

class _ElicitationCardState extends State<ElicitationCard> {
  late final Map<String, Object?> _values = {
    for (final field in widget.request.fields)
      field.name:
          field.defaultValue ??
          (field.type == ElicitationFieldType.multiChoice ? <String>[] : null),
  };
  bool _answered = false;
  bool _opened = false;

  bool get _complete => widget.request.fields.every(
    (field) =>
        !field.required ||
        switch (_values[field.name]) {
          null => false,
          final String text => text.trim().isNotEmpty,
          final List<String> items => items.isNotEmpty,
          _ => true,
        },
  );

  void _answer(String action) {
    if (_answered) return;
    setState(() => _answered = true);
    if (action != 'accept') return widget.onAnswer(action);
    final content = <String, dynamic>{};
    for (final field in widget.request.fields) {
      final value = _values[field.name];
      if (value == null || (value is String && value.trim().isEmpty)) continue;
      content[field.name] = switch (field.type) {
        ElicitationFieldType.integer => int.tryParse('$value') ?? value,
        ElicitationFieldType.number => num.tryParse('$value') ?? value,
        _ => value,
      };
    }
    widget.onAnswer('accept', content);
  }

  Future<void> _open() async {
    final url = Uri.tryParse(widget.request.url ?? '');
    if (url == null) return;
    await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!mounted) return;
    setState(() => _opened = true);
    // The agent closes the question with elicitation/complete once done.
    widget.onAnswer('accept');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final request = widget.request;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 760,
          maxHeight: MediaQuery.sizeOf(context).height * .6,
        ),
        child: BayaSurface(
          key: const Key('elicitation-card'),
          role: BayaSurfaceRole.overlay,
          radius: 22,
          emphasized: true,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        request.isLink
                            ? LucideIcons.externalLink
                            : LucideIcons.messageCircleQuestion,
                        size: 17,
                        color: colors.accent,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        request.title?.isNotEmpty == true
                            ? request.title!
                            : request.message,
                        style: context.typo.sansBody.copyWith(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (request.title?.isNotEmpty == true) ...[
                  const SizedBox(height: 6),
                  Text(
                    request.message,
                    style: context.typo.sansBody.copyWith(color: colors.muted2),
                  ),
                ],
                if (request.isLink) ...[
                  const SizedBox(height: 10),
                  Text(
                    request.url!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.monoSmall,
                  ),
                ],
                for (final field in request.fields) ...[
                  const SizedBox(height: 12),
                  _Field(
                    field: field,
                    value: _values[field.name],
                    onChanged: (value) =>
                        setState(() => _values[field.name] = value),
                  ),
                ],
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    TextButton(
                      key: const Key('elicitation-decline'),
                      onPressed: _answered ? null : () => _answer('decline'),
                      child: Text(context.l10n.decline),
                    ),
                    if (request.isLink)
                      FilledButton(
                        key: const Key('elicitation-open'),
                        onPressed: _opened ? null : _open,
                        child: Text(
                          _opened
                              ? context.l10n.waitingForAgent
                              : context.l10n.openLink,
                        ),
                      )
                    else
                      FilledButton(
                        key: const Key('elicitation-accept'),
                        onPressed: _answered || !_complete
                            ? null
                            : () => _answer('accept'),
                        child: Text(context.l10n.submit),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.field,
    required this.value,
    required this.onChanged,
  });

  final ElicitationField field;
  final Object? value;
  final ValueChanged<Object?> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final label = Text(
      field.required ? '${field.title} *' : field.title,
      style: context.typo.sansBody.copyWith(fontSize: 13, color: colors.muted2),
    );
    switch (field.type) {
      case ElicitationFieldType.boolean:
        return SwitchListTile(
          key: ValueKey('field-${field.name}'),
          contentPadding: EdgeInsets.zero,
          title: Text(field.title),
          value: value == true,
          onChanged: onChanged,
        );
      case ElicitationFieldType.choice:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            label,
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (option, title) in field.options)
                  ChoiceChip(
                    key: ValueKey('field-${field.name}-$option'),
                    label: Text(title),
                    selected: value == option,
                    onSelected: (_) => onChanged(option),
                  ),
              ],
            ),
          ],
        );
      case ElicitationFieldType.multiChoice:
        final selected = (value as List<String>?) ?? const [];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            label,
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (option, title) in field.options)
                  FilterChip(
                    label: Text(title),
                    selected: selected.contains(option),
                    onSelected: (on) => onChanged(
                      on
                          ? [...selected, option]
                          : selected.where((o) => o != option).toList(),
                    ),
                  ),
              ],
            ),
          ],
        );
      case ElicitationFieldType.text:
      case ElicitationFieldType.number:
      case ElicitationFieldType.integer:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            label,
            const SizedBox(height: 6),
            TextFormField(
              key: ValueKey('field-${field.name}'),
              initialValue: value?.toString(),
              keyboardType: switch (field.type) {
                ElicitationFieldType.text => switch (field.format) {
                  'email' => TextInputType.emailAddress,
                  'uri' => TextInputType.url,
                  _ => TextInputType.text,
                },
                _ => const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
              },
              onChanged: onChanged,
            ),
          ],
        );
    }
  }
}
