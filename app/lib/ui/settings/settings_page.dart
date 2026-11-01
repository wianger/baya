import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/relay_config.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_glass_surface.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/core/widgets/baya_notice.dart';
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
    final colors = context.colors;
    final vm = context.watch<SettingsViewModel>();
    final prefs = context.watch<Preferences>();

    return Scaffold(
      backgroundColor: embedded ? Colors.transparent : colors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        flexibleSpace: const BayaGlassSurface(
          role: BayaGlassRole.navigation,
          radius: 0,
          elevated: false,
          child: SizedBox.expand(),
        ),
        title: const Text('Settings'),
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: Icon(
            embedded ? LucideIcons.x : LucideIcons.chevronLeft,
            size: embedded ? 22 : 18,
            color: colors.text,
          ),
          tooltip: embedded ? 'Close' : 'Back',
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
                    const _SettingsSectionLabel('Connection'),
                    _SettingsEntryCard(
                      child: _SettingsEntry(
                        key: const Key('settings-relay'),
                        icon: LucideIcons.settings2,
                        title: 'Relay',
                        subtitle: vm.effectiveRelayUrl,
                        onTap: () => _openDetail(
                          context,
                          () => const RelaySettingsPage(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    const _SettingsSectionLabel('Chat & appearance'),
                    _SettingsEntryCard(
                      child: _SettingsEntry(
                        key: const Key('settings-display'),
                        icon: LucideIcons.monitor,
                        title: 'Display and conversation',
                        subtitle: _displaySummary(prefs),
                        onTap: () => _openDetail(
                          context,
                          () => const DisplaySettingsPage(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    const _SettingsSectionLabel('Information'),
                    _SettingsEntryCard(
                      child: _SettingsEntry(
                        key: const Key('settings-about'),
                        icon: LucideIcons.info,
                        title: 'About',
                        subtitle:
                            'Version, updates and project links',
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
      ThemeMode.system => 'System',
      ThemeMode.light => 'Light',
      ThemeMode.dark => 'Dark',
    };
    final tools = prefs.hideToolCalls ? 'Tools hidden' : 'Tools visible';
    return '$theme · ${prefs.fontScale.label} text · $tools';
  }
}

class RelaySettingsPage extends StatefulWidget {
  const RelaySettingsPage({super.key});

  @override
  State<RelaySettingsPage> createState() => _RelaySettingsPageState();
}

class _RelaySettingsPageState extends State<RelaySettingsPage> {
  late final TextEditingController _ctrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    final vm = context.read<SettingsViewModel>();
    _ctrl = TextEditingController(text: vm.relayUrlOverride);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final vm = context.read<SettingsViewModel>();
    final err = await vm.saveRelayUrl(_ctrl.text);
    if (!mounted) return;
    setState(() => _error = err);
    if (err == null) {
      await showBayaNotice(
        context,
        title: 'Relay updated',
        message: 'This device now uses the new relay URL.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<SettingsViewModel>();
    final colors = context.colors;
    return _SettingsDetailScaffold(
      title: 'Relay',
      child: BayaGlassSurface(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Server address',
              style: context.typo.sansBody.copyWith(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'The app reconnects after a new relay is saved.',
              style: context.typo.sansBody.copyWith(
                color: colors.muted,
                fontSize: 13,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('relay-url'),
              controller: _ctrl,
              autocorrect: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              style: context.typo.mono.copyWith(
                fontSize: 13,
                color: colors.text,
              ),
              decoration: InputDecoration(
                hintText: 'https://my-relay.example.com',
                hintStyle: context.typo.mono.copyWith(
                  color: colors.muted,
                  fontSize: 12,
                ),
                helperText: 'Current: ${vm.effectiveRelayUrl}',
                helperMaxLines: 2,
                helperStyle: context.typo.mono.copyWith(
                  fontSize: 10,
                  color: colors.muted,
                ),
                errorText: _error,
                errorMaxLines: 3,
                errorStyle: context.typo.mono.copyWith(
                  fontSize: 10,
                  color: colors.error,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: colors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: colors.accent),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                FilledButton(
                  key: const Key('relay-save'),
                  onPressed: _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.accent,
                    foregroundColor: colors.onAccent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    shape: const StadiumBorder(),
                  ),
                  child: Text(
                    'Save',
                    style: const TextStyle(
                      fontFamily: kMonoFamily,
                      fontSize: 13,
                    ),
                  ),
                ),
                TextButton(
                  key: const Key('relay-use-default'),
                  onPressed: () {
                    _ctrl.text = kDefaultRelayUrl;
                    _save();
                  },
                  child: Text(
                    'Use default relay',
                    style: const TextStyle(
                      fontFamily: kMonoFamily,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
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
      title: 'Display and conversation',
      child: BayaGlassSurface(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DetailControl(
              title: 'Theme',
              description: 'Follow Android or keep one appearance.',
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<ThemeMode>(
                  key: const Key('theme-selector'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('System'),
                    ),
                    ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                    ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                  ],
                  selected: {prefs.themeMode},
                  onSelectionChanged: (selection) =>
                      prefs.setThemeMode(selection.first),
                ),
              ),
            ),
            Divider(color: colors.border, height: 32),
            _DetailControl(
              title: 'Text size',
              description: 'Scale the whole app, including chat text.',
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<AppFontScale>(
                  key: const Key('font-scale-selector'),
                  showSelectedIcon: false,
                  segments: [
                    for (final scale in AppFontScale.values)
                      ButtonSegment(value: scale, label: Text(scale.label)),
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
                'Hide tool calls in chat',
                style: context.typo.sansBody.copyWith(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                'Only show your messages and assistant replies.',
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
        flexibleSpace: const BayaGlassSurface(
          role: BayaGlassRole.navigation,
          radius: 0,
          elevated: false,
          child: SizedBox.expand(),
        ),
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: Icon(LucideIcons.chevronLeft, size: 20, color: colors.text),
          tooltip: 'Back',
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
    return BayaGlassSurface(
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
