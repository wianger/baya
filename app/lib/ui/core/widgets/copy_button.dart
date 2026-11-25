import 'dart:async';

import 'package:app/l10n/l10n.dart';

import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Compact clipboard action with inline success feedback. Callers provide the
/// key so each independently copyable content section can expose a stable
/// target for accessibility and tests.
class BayaCopyButton extends StatefulWidget {
  const BayaCopyButton({
    super.key,
    required this.text,
    this.color,
    this.tooltip = 'Copy',
  });

  final String text;
  final Color? color;
  final String tooltip;

  @override
  State<BayaCopyButton> createState() => _BayaCopyButtonState();
}

class _BayaCopyButtonState extends State<BayaCopyButton> {
  bool _copied = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tint = _copied ? colors.accent : (widget.color ?? colors.muted);
    // An icon alone, as Claude's code blocks have it; a tick once copied.
    return IconButton(
      onPressed: _copy,
      tooltip: _copied ? context.l10n.copied : widget.tooltip,
      visualDensity: VisualDensity.compact,
      iconSize: 16,
      color: tint,
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: Icon(
          _copied ? LucideIcons.check : LucideIcons.copy,
          key: ValueKey(_copied),
        ),
      ),
    );
  }
}
