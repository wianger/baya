import 'dart:async';

import 'package:app/data/hosts/session_controller.dart';
import 'package:app/data/preview/preview_proxy.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/code/code_view.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/preview/preview_page.dart';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/custom_widgets/unordered_ordered_list.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';
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
      linkLocalhost(data),
      style: base,
      onLinkTap: (url, _) => _openLink(context, url),
      // A chip that takes its own room in the line, so the words around
      // it keep their spaces.
      inlineCodeBuilder: (context, code, style, codeStyle) =>
          baselineWidgetSpan(
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.selection,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 5,
                  vertical: 1.5,
                ),
                child: Text(
                  code,
                  style: typo.mono.copyWith(
                    fontSize: 12.5,
                    height: 1.35,
                    color: colors.accent,
                    letterSpacing: -0.1,
                  ),
                ),
              ),
            ),
          ),
      blockQuoteBuilder: (context, content, style) =>
          _QuoteCard(edge: colors.accent, child: content),
      // GitHub's `> [!WARNING]`: the same card, titled, its edge in the
      // colour of what it says.
      alertBuilder: (context, alert) => _QuoteCard(
        edge: switch (alert.type) {
          MarkdownAlertType.note => colors.accent,
          MarkdownAlertType.tip => colors.success,
          MarkdownAlertType.important => colors.working,
          MarkdownAlertType.warning => colors.warning,
          MarkdownAlertType.caution => colors.error,
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DefaultTextStyle.merge(
              style: const TextStyle(fontWeight: FontWeight.w600),
              child: IconTheme.merge(
                data: IconThemeData(
                  size: 16,
                  color: switch (alert.type) {
                    MarkdownAlertType.note => colors.accent,
                    MarkdownAlertType.tip => colors.success,
                    MarkdownAlertType.important => colors.working,
                    MarkdownAlertType.warning => colors.warning,
                    MarkdownAlertType.caution => colors.error,
                  },
                ),
                child: alert.title,
              ),
            ),
            const SizedBox(height: 4),
            alert.content,
          ],
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

final _bareLocal = RegExp(
  r'(^|\s|(?<!\])\()(https?://(?:localhost|\[::1\])(?::\d+)?(?:[/?#][^\s<>`]*)?)',
  multiLine: true,
);

/// GFM links bare URLs only on a domain with a dot, so the agent's
/// `http://localhost:5173` would stay text: put it in `<>`, outside code.
@visibleForTesting
String linkLocalhost(String markdown) {
  if (!markdown.contains('://localhost') && !markdown.contains('://[::1]')) {
    return markdown;
  }
  final out = StringBuffer();
  var fence = false;
  for (final (i, line) in markdown.split('\n').indexed) {
    if (i > 0) out.write('\n');
    if (RegExp(r'^\s{0,3}(```|~~~)').hasMatch(line)) fence = !fence;
    if (fence || line.startsWith('    ')) {
      out.write(line);
      continue;
    }
    // Odd parts sit between backticks: code, left alone.
    for (final (j, part) in line.split('`').indexed) {
      if (j > 0) out.write('`');
      out.write(
        j.isOdd
            ? part
            : part.replaceAllMapped(_bareLocal, (m) {
                var url = m[2]!;
                // Sentence punctuation after a URL is not part of it.
                final tail = RegExp(r'[.,;:!?)]+$').firstMatch(url)?[0] ?? '';
                url = url.substring(0, url.length - tail.length);
                return '${m[1]}<$url>$tail';
              }),
      );
    }
  }
  return out.toString();
}

/// A quote: a quiet card with an edge in [edge], as the transcript's other
/// surfaces.
class _QuoteCard extends StatelessWidget {
  const _QuoteCard({required this.edge, required this.child});

  final Color edge;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: BayaSurface(
      role: BayaSurfaceRole.content,
      radius: 13,
      elevated: false,
      emphasized: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(13, 10, 13, 10),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: edge.withValues(alpha: 0.55), width: 2.5),
          ),
        ),
        child: child,
      ),
    ),
  );
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
