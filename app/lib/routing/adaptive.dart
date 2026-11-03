import 'package:flutter/widgets.dart';

/// Shortest side (logical pixels) at which the app switches to the two-pane
/// tablet layout.
const double kTabletBreakpoint = 600.0;

/// Whether the window is tablet-class in any orientation.
///
/// Uses `shortestSide`, not `width`, so a phone in landscape stays a phone,
/// while a narrow multitasking window on a tablet still collapses to one pane
/// (MediaQuery measures the window, not the device).
bool isWideLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).shortestSide >= kTabletBreakpoint;

/// Max width of single-column content (onboarding, empty states), so tablets
/// do not get a stretched phone UI.
const double kMaxContentWidth = 460.0;

/// Centers [child] on both axes and caps its width on wide screens.
class ResponsiveCenter extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  const ResponsiveCenter({
    super.key,
    required this.child,
    this.maxWidth = kMaxContentWidth,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// Adaptive shell layout state. [isZeroState] is `true` when there is
/// nothing to list (no paired computer or no sessions); the shell then shows
/// one centered pane instead of a split with an empty placeholder. It starts
/// `false` so the common case does not flash single → split at boot.
class ShellLayout extends ChangeNotifier {
  bool _zeroState = false;
  bool get isZeroState => _zeroState;

  void setZeroState(bool value) {
    if (value == _zeroState) return;
    _zeroState = value;
    notifyListeners();
  }
}

/// The session selected in the UI (the tablet detail pane, highlighted in
/// the list). Starts `null` so no chat is preselected at launch, and is not
/// restored between runs.
class SessionSelection extends ChangeNotifier {
  ({
    String hostKey,
    String sessionId,
    String title,
    String device,
    bool online,
  })?
  _current;

  ({
    String hostKey,
    String sessionId,
    String title,
    String device,
    bool online,
  })?
  get current => _current;

  bool matches(String hostKey, String sessionId) {
    final c = _current;
    return c != null && c.hostKey == hostKey && c.sessionId == sessionId;
  }

  /// [device] and [online] are what the list already knows, so the chat
  /// header renders right away.
  void select(
    String hostKey,
    String sessionId,
    String title, [
    String device = '',
    bool online = false,
  ]) {
    if (matches(hostKey, sessionId)) return;
    _current = (
      hostKey: hostKey,
      sessionId: sessionId,
      title: title,
      device: device,
      online: online,
    );
    notifyListeners();
  }

  void clear() {
    if (_current == null) return;
    _current = null;
    notifyListeners();
  }
}
