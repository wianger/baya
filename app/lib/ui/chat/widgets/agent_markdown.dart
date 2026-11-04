import 'dart:async';

import 'package:app/data/hosts/session_controller.dart';
import 'package:app/data/preview/preview_proxy.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/preview/preview_page.dart';
import 'package:provider/provider.dart';
import 'package:app/ui/core/code/code_view.dart';

import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart';
import 'package:gpt_markdown/custom_widgets/unordered_ordered_list.dart';
import 'package:url_launcher/url_launcher.dart';

/// Renders the agent's Markdown reply (GFM + code) themed to the
/// app's dark/mono look. Links open in the system browser (url_launcher);
/// code blocks get a copy button. Tolerant of partial markdown so it can also
/// drive the live streaming bubble.
class AgentMarkdown extends StatelessWidget {
  const AgentMarkdown(
    this.data, {
    super.key,
    this.selectable = false,
    this.fontSize = 15,
    this.color,
  });

  final String data;
  final double fontSize;

  /// Prose colour; the theme's text colour when null.
  final Color? color;

  /// Wrap in a [SelectionArea] so prose/code can be selected + copied. Off for
  /// the streaming bubble (content changes every frame).
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final typo = context.typo;
    final base = typo.reading.copyWith(
      fontSize: fontSize,
      height: 1.5,
      letterSpacing: -0.11,
      color: color,
    );
    // A calm reading rhythm: sans-serif prose, tight display headings and
    // generous line height. Heading scale stays restrained on a phone.
    final mdTheme = GptMarkdownThemeData(
      brightness: Theme.of(context).brightness,
      highlightColor: colors.selection,
      linkColor: colors.accent,
      linkHoverColor: colors.accent,
      hrLineColor: colors.border,
      hrLineThickness: .5,
      hrLinePadding: const EdgeInsets.symmetric(vertical: 16),
      autoAddDividerLineAfterH1: false,
      h1: base.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        height: 1.2,
        letterSpacing: -0.55,
      ),
      h2: base.copyWith(
        fontSize: 20.5,
        fontWeight: FontWeight.w700,
        height: 1.22,
        letterSpacing: -0.4,
      ),
      h3: base.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        height: 1.28,
        letterSpacing: -0.28,
      ),
      h4: base.copyWith(
        fontSize: 16.5,
        fontWeight: FontWeight.w600,
        height: 1.32,
        letterSpacing: -0.2,
      ),
      h5: base.copyWith(
        fontSize: 15.5,
        fontWeight: FontWeight.w600,
        height: 1.35,
        letterSpacing: -0.15,
      ),
      h6: base.copyWith(
        fontSize: 14.5,
        fontWeight: FontWeight.w600,
        height: 1.4,
        color: colors.muted2,
      ),
    );
    final markdown = GptMarkdown(
      data,
      style: base,
      onLinkTap: (url, _) => _openLink(context, url),
      highlightBuilder: (context, text, style) => DecoratedBox(
        decoration: BoxDecoration(
          color: colors.selection,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
          child: Text(
            text,
            style: typo.mono.copyWith(
              fontSize: 12.5,
              height: 1.35,
              color: colors.accent,
              letterSpacing: -0.1,
            ),
          ),
        ),
      ),
      // Fenced ``` blocks — dark card + copy button.
      codeBuilder: (context, name, code, closed) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: CodeBlock(code: code, language: name, foldAfter: 40),
      ),
      // The package defaults to generous list indents. A transcript
      // style keeps bullets compact and aligns their text with the prose.
      unOrderedListBuilder: (context, child, config) => UnorderedListView(
        spacing: 5,
        padding: 8,
        bulletSize: 3.5,
        bulletColor: colors.accent,
        child: child,
      ),
      orderedListBuilder: (context, no, child, config) => OrderedListView(
        no: no,
        spacing: 5,
        padding: 3,
        style: base.copyWith(
          fontSize: 14,
          height: 1.45,
          fontWeight: FontWeight.w600,
          color: colors.muted2,
        ),
        child: child,
      ),
      tableBuilder: (context, rows, style, config) =>
          _MarkdownTable(rows: rows, style: style),
      components: MarkdownComponent.globalComponents
          .map<MarkdownComponent>(
            (component) =>
                component is BlockQuote ? _QuietBlockQuote() : component,
          )
          .toList(growable: false),
    );
    final themed = GptMarkdownTheme(gptThemeData: mdTheme, child: markdown);
    return selectable ? SelectionArea(child: themed) : themed;
  }

  static Future<void> _openLink(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    // A site on the agent's computer opens in the web preview: the phone
    // has no `localhost` of its own.
    final port = localPort(uri);
    final session = port == null
        ? null
        : Provider.of<SessionController?>(context, listen: false);
    if (port != null && session != null) {
      return openPreview(
        context,
        session.host,
        port,
        path:
            '${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}',
      );
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (ok || !context.mounted) return;
      await showBayaNotice(
        context,
        title: context.l10n.couldNotOpenLink,
        message: url,
      );
    } catch (_) {
      if (!context.mounted) return;
      await showBayaNotice(
        context,
        title: context.l10n.couldNotOpenLink,
        message: url,
      );
    }
  }
}

class _QuietBlockQuote extends BlockQuote {
  _QuietBlockQuote();

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final match = exp.firstMatch(text);
    final lines = <String>[];
    for (final line in (match?[0] ?? '').split('\n')) {
      if (line.startsWith(RegExp(r'\s*>'))) {
        var content = line.trimLeft().substring(1);
        if (content.startsWith(' ')) content = content.substring(1);
        lines.add(content);
      } else {
        lines.add(line);
      }
    }
    final colors = context.colors;
    final data = lines.join('\n').trim();
    final child = TextSpan(
      children: MarkdownComponent.generate(context, data, config, true),
    );
    return TextSpan(
      children: [
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Directionality(
            textDirection: config.textDirection,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: BayaSurface(
                role: BayaSurfaceRole.content,
                radius: 13,
                elevated: false,
                emphasized: true,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(13, 10, 13, 10),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        color: colors.accent.withValues(alpha: 0.55),
                        width: 2.5,
                      ),
                    ),
                  ),
                  child: config.getRich(child),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MarkdownTable extends StatelessWidget {
  const _MarkdownTable({required this.rows, required this.style});

  final List<CustomTableRow> rows;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final columns = rows.isEmpty ? 0 : rows.first.fields.length;
    if (columns == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: SizedBox(
        width: double.infinity,
        child: BayaSurface(
          role: BayaSurfaceRole.content,
          radius: 14,
          elevated: false,
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: constraints.hasBoundedWidth
                      ? constraints.maxWidth
                      : 0,
                ),
                child: Table(
                  defaultColumnWidth: const IntrinsicColumnWidth(),
                  border: TableBorder(
                    horizontalInside: BorderSide(
                      color: colors.border.withValues(alpha: 0.55),
                      width: 0.5,
                    ),
                  ),
                  children: [
                    for (final row in rows)
                      TableRow(
                        decoration: BoxDecoration(
                          color: row.isHeader
                              ? colors.codeBg.withValues(alpha: 0.52)
                              : null,
                        ),
                        children: [
                          for (final field in row.fields)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: Text(
                                field.data.trim(),
                                textAlign: field.alignment,
                                style: style.copyWith(
                                  fontSize: 13,
                                  height: 1.35,
                                  fontWeight: row.isHeader
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: row.isHeader
                                      ? colors.text
                                      : colors.muted2,
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
