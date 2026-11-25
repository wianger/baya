import 'dart:async';

import 'package:app/data/agents/agent_notifier.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/pairing/backed_up_identity_store.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_group.dart';
import 'package:app/ui/core/widgets/baya_header.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/core/widgets/liquid_morph.dart';
import 'package:app/ui/settings/adb_page.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

class SettingsPage extends StatelessWidget {
  /// Plan/tablet — `true` when presented as a modal bottom sheet (tablet)
  /// rather than a pushed full-screen route (phone). Swaps the back arrow
  /// for a close (X), since the sheet is dismissed, not popped to a parent.
  final bool embedded;

  const SettingsPage({super.key, this.embedded = false});

  /// Pushed detail routes are siblings of `/settings` in the navigator, so
  /// they do NOT inherit the route-local `SettingsViewModel` provider. Re-inject
  /// the same instance or the detail page throws when it reads the ViewModel.
  void _openDetail(BuildContext context, Widget Function() page) {
    final vm = context.read<SettingsViewModel>();
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChangeNotifierProvider<SettingsViewModel>.value(
          value: vm,
          child: page(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<Preferences>();

    // DeepSeek's settings: a tinted page, the title centred, a floating
    // close circle on the right, white cards below.
    return BayaTintedPage(
      child: Scaffold(
        backgroundColor: BayaTintedPage.ground(context),
        appBar: BayaHeader(
          title: context.l10n.settings,
          leading: HeaderLeading.none,
          actions: [
            HeaderAction(
              icon: LucideIcons.x,
              tooltip: context.l10n.close,
              onPressed: () =>
                  context.canPop() ? context.pop() : context.go('/home'),
            ),
          ],
        ),
        body: BayaBackdrop(
          translucent: true,
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: BayaReveal(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 36),
                    children: [
                      const _KeyBackupEntry(),
                      BayaSectionLabel(context.l10n.chatAndAppearance),
                      // As DeepSeek lays these out: choices open a small
                      // menu where they are, text size has its own page.
                      BayaGroup(
                        children: [
                          _ChoiceRow<String>(
                            key: const Key('settings-language'),
                            icon: LucideIcons.globe,
                            label: context.l10n.language,
                            value: prefs.language ?? '',
                            choices: {
                              '': context.l10n.themeSystem,
                              'en': 'English',
                              'zh': '中文',
                            },
                            onChanged: (value) =>
                                prefs.setLanguage(value.isEmpty ? null : value),
                          ),
                          _ChoiceRow<ThemeMode>(
                            key: const Key('settings-theme'),
                            icon: LucideIcons.sun,
                            label: context.l10n.theme,
                            value: prefs.themeMode,
                            choices: {
                              ThemeMode.system: context.l10n.themeSystem,
                              ThemeMode.dark: context.l10n.themeDark,
                              ThemeMode.light: context.l10n.themeLight,
                            },
                            onChanged: prefs.setThemeMode,
                          ),
                          BayaRow(
                            key: const Key('settings-font-size'),
                            icon: LucideIcons.aLargeSmall,
                            label: context.l10n.textSize,
                            value: prefs.fontScale.localizedLabel(context.l10n),
                            chevron: true,
                            onTap: () => _openDetail(
                              context,
                              () => const FontSizePage(),
                            ),
                          ),
                          BayaRow(
                            key: const Key('hide-tool-calls'),
                            icon: LucideIcons.wrench,
                            label: context.l10n.hideToolCalls,
                            // The row is the control; the switch only shows it.
                            trailing: ExcludeSemantics(
                              child: Switch(
                                value: prefs.hideToolCalls,
                                onChanged: prefs.setHideToolCalls,
                              ),
                            ),
                            onTap: () =>
                                prefs.setHideToolCalls(!prefs.hideToolCalls),
                          ),
                          _ChoiceRow<TerminalEngine>(
                            key: const Key('settings-terminal-engine'),
                            icon: LucideIcons.squareTerminal,
                            label: context.l10n.terminalEngine,
                            value: prefs.terminalEngine,
                            choices: {
                              TerminalEngine.xterm: 'xterm',
                              TerminalEngine.ghostty:
                                  context.l10n.terminalEngineGhostty,
                            },
                            onChanged: prefs.setTerminalEngine,
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      BayaSectionLabel(context.l10n.phoneSection),
                      BayaGroup(
                        children: [
                          const _NotificationsRow(),
                          BayaRow(
                            key: const Key('settings-adb'),
                            icon: LucideIcons.smartphone,
                            label: context.l10n.phoneForAgents,
                            chevron: true,
                            onTap: () =>
                                _openDetail(context, () => const AdbPage()),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      BayaSectionLabel(context.l10n.information),
                      BayaGroup(
                        children: [
                          BayaRow(
                            key: const Key('settings-about'),
                            icon: LucideIcons.info,
                            label: context.l10n.about,
                            chevron: true,
                            onTap: () => context.push('/about'),
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
      ),
    );
  }
}

class _SettingsDetailScaffold extends StatelessWidget {
  const _SettingsDetailScaffold({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return BayaTintedPage(
      child: Scaffold(
        backgroundColor: BayaTintedPage.ground(context),
        appBar: BayaHeader(title: title),
        body: BayaBackdrop(
          translucent: true,
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: BayaReveal(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 36),
                    children: [child],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NotificationsRow extends StatefulWidget {
  const _NotificationsRow();

  @override
  State<_NotificationsRow> createState() => _NotificationsRowState();
}

class _NotificationsRowState extends State<_NotificationsRow>
    with WidgetsBindingObserver {
  AgentNotifier? _notifier;

  /// Whether Android lets the app post them; null until known.
  bool? _allowed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final notifier = context.read<AgentNotifier?>();
    if (notifier == _notifier) return;
    _notifier = notifier;
    unawaited(_check());
  }

  // Back from Android's settings.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  Future<void> _check() async {
    final allowed = await _notifier?.allowed();
    if (mounted && allowed != _allowed) setState(() => _allowed = allowed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<Preferences>();
    final blocked = prefs.notifyAgents && _allowed == false;
    Future<void> toggle() async {
      if (blocked) return _notifier?.ask(settings: true);
      final on = !prefs.notifyAgents;
      await prefs.setNotifyAgents(on);
      if (on) await _notifier?.ask(settings: true);
    }

    // One node for screen readers: the label, and the switch's state.
    return MergeSemantics(
      child: BayaRow(
        key: const Key('settings-notifications'),
        icon: blocked ? LucideIcons.bellOff : LucideIcons.bellRing,
        label: context.l10n.notifications,
        trailing: Switch(
          value: prefs.notifyAgents && !blocked,
          onChanged: (_) => unawaited(toggle()),
        ),
        onTap: () => unawaited(toggle()),
      ),
    );
  }
}

class _KeyBackupEntry extends StatelessWidget {
  const _KeyBackupEntry();

  @override
  Widget build(BuildContext context) {
    final BackedUpOwnerIdentityStore store;
    try {
      store = context.watch<BackedUpOwnerIdentityStore>();
    } on ProviderNotFoundException {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BayaSectionLabel(l10n.security),
        BayaGroup(
          children: [
            BayaRow(
              key: const Key('settings-key-backup'),
              icon: store.backedUp
                  ? LucideIcons.cloudCheck
                  : LucideIcons.cloudAlert,
              label: l10n.keyBackup,
              chevron: true,
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => ChangeNotifierProvider.value(
                    value: store,
                    child: const KeyBackupPage(),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
      ],
    );
  }
}

/// Where the phone's owner key lives, and backing it up now.
class KeyBackupPage extends StatefulWidget {
  const KeyBackupPage({super.key});

  @override
  State<KeyBackupPage> createState() => _KeyBackupPageState();
}

class _KeyBackupPageState extends State<KeyBackupPage> {
  bool _busy = false;
  bool? _lastTry;

  Future<void> _backUp(BackedUpOwnerIdentityStore store) async {
    setState(() => _busy = true);
    final ok = await store.retryBackup();
    if (mounted) {
      setState(() {
        _busy = false;
        _lastTry = ok;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<BackedUpOwnerIdentityStore>();
    final colors = context.colors;
    final l10n = context.l10n;
    final backedUp = store.backedUp;
    return _SettingsDetailScaffold(
      title: l10n.keyBackup,
      child: BayaSurface(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  backedUp ? LucideIcons.cloudCheck : LucideIcons.cloudAlert,
                  size: 22,
                  color: backedUp ? colors.success : colors.warning,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    backedUp ? l10n.keyBackedUp : l10n.keyNotBackedUp,
                    key: const Key('key-backup-status'),
                    style: context.typo.sansBody.copyWith(
                      fontSize: BayaType.callout,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              l10n.keyBackupExplain,
              style: context.typo.sansBody.copyWith(
                color: colors.muted2,
                height: 1.45,
              ),
            ),
            if (!backedUp) ...[
              const SizedBox(height: 12),
              Text(
                l10n.keyBackupHowTo,
                style: context.typo.sansBody.copyWith(
                  color: colors.muted,
                  fontSize: BayaType.footnote,
                  height: 1.45,
                ),
              ),
            ],
            if (_lastTry == false) ...[
              const SizedBox(height: 12),
              Text(
                l10n.keyBackupFailed,
                key: const Key('key-backup-failed'),
                style: context.typo.sansBody.copyWith(
                  color: colors.error,
                  fontSize: BayaType.footnote,
                ),
              ),
            ],
            const SizedBox(height: 18),
            FilledButton.icon(
              key: const Key('key-backup-now'),
              onPressed: _busy ? null : () => _backUp(store),
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 1.8),
                    )
                  : const Icon(LucideIcons.cloudUpload, size: 18),
              label: Text(backedUp ? l10n.keyBackupAgain : l10n.keyBackupNow),
            ),
          ],
        ),
      ),
    );
  }
}

/// A setting chosen from a few: the choice on the right, and a small menu
/// with a check where the row is.
class _ChoiceRow<T> extends StatelessWidget {
  const _ChoiceRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.choices,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final T value;
  final Map<T, String> choices;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Builder(
      builder: (rowContext) => BayaRow(
        icon: icon,
        label: label,
        value: choices[value],
        trailing: Icon(
          LucideIcons.chevronsUpDown,
          size: 16,
          color: colors.muted,
        ),
        onTap: () async {
          final box = rowContext.findRenderObject()! as RenderBox;
          final rowTop = box.localToGlobal(Offset.zero);
          final screen = MediaQuery.sizeOf(rowContext);
          // A small card that swells out of the row's value.
          final picked = await showLiquid<T>(
            context: rowContext,
            barrierColor: Colors.black.withValues(alpha: .08),
            builder: (menuContext) => Stack(
              children: [
                Positioned(
                  right: screen.width - rowTop.dx - box.size.width + 16,
                  top: rowTop.dy + box.size.height * .6,
                  width: 220,
                  child: LiquidMorph(
                    borderRadius: BorderRadius.circular(24),
                    child: BayaSurface(
                      role: BayaSurfaceRole.floating,
                      radius: 24,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final MapEntry(key: choice, value: name)
                              in choices.entries)
                            InkWell(
                              onTap: () =>
                                  Navigator.of(menuContext).pop(choice),
                              child: SizedBox(
                                height: 50,
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 46,
                                      child: choice == value
                                          ? Icon(
                                              LucideIcons.check,
                                              size: 18,
                                              color: colors.text,
                                            )
                                          : null,
                                    ),
                                    Expanded(
                                      child: Text(
                                        name,
                                        style: context.typo.sansBody.copyWith(
                                          fontSize: BayaType.callout,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
          if (picked != null) onChanged(picked);
        },
      ),
    );
  }
}

/// Text size, as DeepSeek sets it: a preview card, then a slider from small
/// to large.
class FontSizePage extends StatelessWidget {
  const FontSizePage({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<Preferences>();
    final colors = context.colors;
    const scales = AppFontScale.values;
    final index = scales.indexOf(prefs.fontScale);
    return _SettingsDetailScaffold(
      title: context.l10n.textSize,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BayaGroup(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
                child: MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(prefs.fontScale.factor),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.centerRight,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.userBubble,
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(22),
                              topRight: Radius.circular(22),
                              bottomLeft: Radius.circular(22),
                              bottomRight: Radius.circular(6),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            child: Text(
                              context.l10n.fontPreviewQuestion,
                              style: context.typo.sansBody,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        context.l10n.fontPreviewAnswer,
                        style: context.typo.reading,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              Text(
                'A',
                style: context.typo.sansBody.copyWith(fontSize: BayaType.body),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    prefs.fontScale.localizedLabel(context.l10n),
                    style: context.typo.sansBody.copyWith(
                      fontSize: BayaType.subhead,
                      color: colors.muted,
                    ),
                  ),
                ),
              ),
              Text('A', style: context.typo.sansBody.copyWith(fontSize: 26)),
            ],
          ),
          Slider(
            key: const Key('font-scale-selector'),
            value: index.toDouble(),
            max: (scales.length - 1).toDouble(),
            divisions: scales.length - 1,
            onChanged: (value) => prefs.setFontScale(scales[value.round()]),
          ),
        ],
      ),
    );
  }
}
