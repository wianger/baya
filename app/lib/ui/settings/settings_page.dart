import 'package:app/data/preferences/preferences.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_surface.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:app/pairing/backed_up_identity_store.dart';
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
    final colors = context.colors;
    final prefs = context.watch<Preferences>();

    return Scaffold(
      backgroundColor: embedded ? Colors.transparent : colors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        flexibleSpace: const BayaSurface(
          role: BayaSurfaceRole.navigation,
          radius: 0,
          elevated: false,
          child: SizedBox.expand(),
        ),
        title: Text(context.l10n.settings),
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: Icon(
            embedded ? LucideIcons.x : LucideIcons.chevronLeft,
            size: embedded ? 22 : 18,
            color: colors.text,
          ),
          tooltip: embedded ? context.l10n.close : context.l10n.back,
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(color: colors.border, height: 1),
        ),
      ),
      body: BayaBackdrop(
        translucent: embedded,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: BayaReveal(
                offset: 8,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 36),
                  children: [
                    _SettingsSectionLabel(context.l10n.connection),
                    const _KeyBackupEntry(),
                    const SizedBox(height: 22),
                    _SettingsSectionLabel(context.l10n.chatAndAppearance),
                    _SettingsEntryCard(
                      child: _SettingsEntry(
                        key: const Key('settings-display'),
                        icon: LucideIcons.monitor,
                        title: context.l10n.displayAndConversation,
                        subtitle: _displaySummary(prefs),
                        onTap: () => _openDetail(
                          context,
                          () => const DisplaySettingsPage(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    _SettingsSectionLabel(context.l10n.information),
                    _SettingsEntryCard(
                      child: _SettingsEntry(
                        key: const Key('settings-about'),
                        icon: LucideIcons.info,
                        title: context.l10n.about,
                        subtitle: context.l10n.aboutHint,
                        onTap: () => context.push('/about'),
                      ),
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

  String _displaySummary(Preferences prefs) {
    final theme = switch (prefs.themeMode) {
      ThemeMode.system => appL10n.themeSystem,
      ThemeMode.light => appL10n.themeLight,
      ThemeMode.dark => appL10n.themeDark,
    };
    final tools = prefs.hideToolCalls
        ? appL10n.toolsHidden
        : appL10n.toolsVisible;
    return appL10n.displaySummary(
      theme,
      prefs.fontScale.localizedLabel(appL10n),
      tools,
    );
  }
}

class DisplaySettingsPage extends StatelessWidget {
  const DisplaySettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<Preferences>();
    final colors = context.colors;
    return _SettingsDetailScaffold(
      title: context.l10n.displayAndConversation,
      child: BayaSurface(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DetailControl(
              title: context.l10n.theme,
              description: context.l10n.themeHint,
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<ThemeMode>(
                  key: const Key('theme-selector'),
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text(context.l10n.themeSystem),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      label: Text(context.l10n.themeLight),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text(context.l10n.themeDark),
                    ),
                  ],
                  selected: {prefs.themeMode},
                  onSelectionChanged: (selection) =>
                      prefs.setThemeMode(selection.first),
                ),
              ),
            ),
            Divider(color: colors.border, height: 32),
            _DetailControl(
              title: context.l10n.textSize,
              description: context.l10n.textSizeHint,
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<AppFontScale>(
                  key: const Key('font-scale-selector'),
                  showSelectedIcon: false,
                  segments: [
                    for (final scale in AppFontScale.values)
                      ButtonSegment(
                        value: scale,
                        label: Text(scale.localizedLabel(context.l10n)),
                      ),
                  ],
                  selected: {prefs.fontScale},
                  onSelectionChanged: (selection) =>
                      prefs.setFontScale(selection.first),
                ),
              ),
            ),
            Divider(color: colors.border, height: 32),
            SwitchListTile(
              key: const Key('hide-tool-calls'),
              contentPadding: EdgeInsets.zero,
              activeThumbColor: colors.accent,
              title: Text(
                context.l10n.hideToolCalls,
                style: context.typo.sansBody.copyWith(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                context.l10n.hideToolCallsHint,
                style: context.typo.sansBody.copyWith(
                  color: colors.muted,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              value: prefs.hideToolCalls,
              onChanged: prefs.setHideToolCalls,
            ),
          ],
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
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        flexibleSpace: const BayaSurface(
          role: BayaSurfaceRole.navigation,
          radius: 0,
          elevated: false,
          child: SizedBox.expand(),
        ),
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: Icon(LucideIcons.chevronLeft, size: 20, color: colors.text),
          tooltip: context.l10n.back,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(title),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(color: colors.border, height: 1),
        ),
      ),
      body: BayaBackdrop(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: BayaReveal(
                offset: 8,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 36),
                  children: [child],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailControl extends StatelessWidget {
  const _DetailControl({
    required this.title,
    required this.description,
    required this.child,
  });

  final String title;
  final String description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: context.typo.sansBody.copyWith(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          description,
          style: context.typo.sansBody.copyWith(
            color: colors.muted,
            fontSize: 13,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 12),
        child,
      ],
    );
  }
}

class _SettingsSectionLabel extends StatelessWidget {
  const _SettingsSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: context.colors.muted,
          letterSpacing: 1.4,
        ),
      ),
    );
  }
}

class _SettingsEntryCard extends StatelessWidget {
  const _SettingsEntryCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return BayaSurface(
      radius: 24,
      child: Material(color: Colors.transparent, child: child),
    );
  }
}

class _SettingsEntry extends StatelessWidget {
  const _SettingsEntry({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ListTile(
      minVerticalPadding: 18,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: colors.selection,
          borderRadius: BorderRadius.circular(13),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 20, color: colors.accent),
      ),
      title: Text(
        title,
        style: context.typo.sansBody.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: context.typo.sansBody.copyWith(
            color: colors.muted,
            fontSize: 12,
            height: 1.35,
          ),
        ),
      ),
      trailing: Icon(LucideIcons.chevronRight, size: 18, color: colors.muted),
      onTap: onTap,
    );
  }
}

/// Shows whether the owner key survives a phone change. Never blocks: without
/// Google Backup the app works, the pairing just lives on this phone only.
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
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: _SettingsEntryCard(
        child: _SettingsEntry(
          key: const Key('settings-key-backup'),
          icon: store.backedUp
              ? LucideIcons.cloudCheck
              : LucideIcons.cloudAlert,
          title: l10n.keyBackup,
          subtitle: store.backedUp ? l10n.keyBackedUp : l10n.keyNotBackedUp,
          onTap: () async {
            if (await store.retryBackup() || !context.mounted) return;
            await showBayaNotice(
              context,
              title: l10n.keyBackup,
              message: l10n.keyBackupHowTo,
            );
          },
        ),
      ),
    );
  }
}
