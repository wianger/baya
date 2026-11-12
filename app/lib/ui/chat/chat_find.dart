/// Find in this chat: what was searched, which hit is shown, and the bar that
/// takes the header's place while searching.
library;

import 'package:app/domain/session_state.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The ids of the messages that contain [query], newest first: what was
/// asked and what the agent answered, ignoring case.
List<String> findMatches(List<ChatMessage> messages, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return const [];
  final seen = <String>{};
  final hits = <String>[];
  for (final message in messages.reversed) {
    final text = switch (message) {
      UserMsg(:final text) || AssistantMsg(:final text) => text,
      _ => null,
    };
    if (text == null || !text.toLowerCase().contains(needle)) continue;
    if (seen.add(message.id)) hits.add(message.id);
  }
  return hits;
}

/// Whether the chat is being searched, for what, and which hit is shown
/// (0 is the newest).
class ChatFind extends ChangeNotifier {
  bool _open = false;
  String _query = '';
  int _index = 0;

  bool get open => _open;
  String get query => _query;
  int get index => _index;

  List<ChatMessage>? _of;
  String? _for;
  List<String> _hits = const [];

  /// The hits of the current query in [messages], worked out once per
  /// transcript and query.
  List<String> hits(List<ChatMessage> messages) {
    if (!identical(messages, _of) || _query != _for) {
      _of = messages;
      _for = _query;
      _hits = findMatches(messages, _query);
    }
    return _hits;
  }

  /// The message to show, or null while nothing matches.
  String? current(List<ChatMessage> messages) {
    if (!_open) return null;
    final all = hits(messages);
    if (all.isEmpty) return null;
    return all[_index.clamp(0, all.length - 1)];
  }

  void show() {
    if (_open) return;
    _open = true;
    notifyListeners();
  }

  void close() {
    if (!_open) return;
    _open = false;
    _query = '';
    _index = 0;
    notifyListeners();
  }

  void search(String query) {
    if (query == _query) return;
    _query = query;
    _index = 0;
    notifyListeners();
  }

  /// One hit back in time ([older]) or forward, wrapping around.
  void step(List<ChatMessage> messages, {required bool older}) {
    final count = hits(messages).length;
    if (count == 0) return;
    _index = (_index.clamp(0, count - 1) + (older ? 1 : -1)) % count;
    notifyListeners();
  }
}

/// The search field with the hit count and arrows, in the header's place.
class ChatFindBar extends StatefulWidget {
  const ChatFindBar({super.key, required this.find, required this.messages});

  final ChatFind find;
  final List<ChatMessage> messages;

  @override
  State<ChatFindBar> createState() => _ChatFindBarState();
}

class _ChatFindBarState extends State<ChatFindBar> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _step({required bool older}) {
    HapticFeedback.selectionClick();
    widget.find.step(widget.messages, older: older);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final l10n = context.l10n;
    final find = widget.find;
    final count = find.hits(widget.messages).length;
    final searched = find.query.trim().isNotEmpty;
    final at = count == 0 ? 0 : find.index.clamp(0, count - 1) + 1;
    return SizedBox(
      key: const ValueKey('chat-find-bar'),
      height: 58,
      child: BayaSurface(
        role: BayaSurfaceRole.control,
        radius: 25,
        padding: const EdgeInsets.only(left: 16, right: 4),
        child: Row(
          children: [
            Icon(LucideIcons.search, size: 18, color: colors.muted),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                key: const Key('chat-find-field'),
                controller: _field,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: find.search,
                // Enter keeps the keyboard up and goes one hit further back.
                onSubmitted: (_) => _step(older: true),
                style: context.typo.sansBody.copyWith(
                  fontSize: 15,
                  color: colors.text,
                ),
                // Bare text in the capsule: none of the theme's field box.
                decoration: InputDecoration(
                  isDense: true,
                  filled: false,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: l10n.findInChatHint,
                  hintStyle: TextStyle(color: colors.muted),
                ),
              ),
            ),
            if (searched)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  count == 0 ? l10n.findNoMatches : '$at/$count',
                  key: const Key('chat-find-count'),
                  style: context.typo.monoSmall.copyWith(
                    fontSize: 12,
                    color: count == 0 ? colors.warning : colors.muted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            IconButton(
              key: const Key('chat-find-older'),
              tooltip: l10n.findOlder,
              onPressed: count > 1 ? () => _step(older: true) : null,
              icon: const Icon(LucideIcons.chevronUp, size: 20),
              color: colors.text,
            ),
            IconButton(
              key: const Key('chat-find-newer'),
              tooltip: l10n.findNewer,
              onPressed: count > 1 ? () => _step(older: false) : null,
              icon: const Icon(LucideIcons.chevronDown, size: 20),
              color: colors.text,
            ),
            IconButton(
              key: const Key('chat-find-close'),
              tooltip: l10n.close,
              onPressed: find.close,
              icon: const Icon(LucideIcons.x, size: 20),
              color: colors.muted2,
            ),
          ],
        ),
      ),
    );
  }
}
