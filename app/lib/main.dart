import 'dart:async';

import 'package:app/ui/core/branding/app_brand.dart';
import 'package:app/config/dependencies.dart';
import 'package:app/data/hosts/hosts.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/routing/app_router.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/themes/app_font_licenses.dart';
import 'package:app/l10n/l10n.dart';
import 'package:app/pairing/backed_up_identity_store.dart';
import 'package:app/ui/update/states/update_banner_state.dart';
import 'package:app/ui/update/update_prompt.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerAppFontLicenses();
  await setupDependencies();
  runApp(const BayaApp());
}

class BayaApp extends StatefulWidget {
  const BayaApp({super.key});

  @override
  State<BayaApp> createState() => _BayaAppState();
}

class _BayaAppState extends State<BayaApp> with WidgetsBindingObserver {
  late final _router = buildRouter(
    services.storage,
    services.hosts,
    services.prefs,
    services.ownerBridge,
  );

  StreamSubscription<Uri>? _links;

  /// Newer releases, told about once the app is past boot and onboarding.
  late final _updates = services.viewModel<UpdateBannerViewModel>();
  bool _prompting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Includes the link that cold-started the app.
    _links = AppLinks().uriLinkStream.listen(_openLink);
    _updates.addListener(_onUpdate);
    _router.routerDelegate.addListener(_checkWhenSettled);
  }

  String get _path => _router.routerDelegate.currentConfiguration.uri.path;

  /// Where an update prompt would interrupt: boot, onboarding, pairing.
  bool get _busy => const ['/boot', '/onboarding', '/pair'].contains(_path);

  void _checkWhenSettled() {
    if (_busy) return;
    _router.routerDelegate.removeListener(_checkWhenSettled);
    unawaited(_updates.check());
    // A release found while pairing or onboarding waits until it is done.
    _onUpdate();
  }

  void _onUpdate() {
    final state = _updates.state;
    if (state is! UpdateBannerVisible || _prompting) return;
    if (_busy) {
      _router.routerDelegate.removeListener(_checkWhenSettled);
      _router.routerDelegate.addListener(_checkWhenSettled);
      return;
    }
    final context = _router.routerDelegate.navigatorKey.currentContext;
    if (context == null) return;
    _prompting = true;
    unawaited(
      showUpdatePrompt(
        context,
        _updates,
        state.info,
      ).whenComplete(() => _prompting = false),
    );
  }

  /// Back in the foreground: reconnect now instead of waiting out a backoff.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    services.hosts.reconnectAll();
    // Android keeps the app alive in the background, so opening it is
    // mostly a resume: look again unless we just did.
    if (!_busy) unawaited(_updates.check(after: const Duration(minutes: 10)));
  }

  /// `baya://pair?…` opens pairing with the code already filled in. A link
  /// that arrives during boot waits until the router has left /boot.
  void _openLink(Uri uri) {
    if (uri.scheme != 'baya' || uri.host != 'pair') return;
    String path() => _router.routerDelegate.currentConfiguration.uri.path;
    void open() => _router.push('/pair', extra: uri.toString());
    if (path() != '/boot') return open();
    void whenBooted() {
      if (path() == '/boot') return;
      _router.routerDelegate.removeListener(whenBooted);
      open();
    }

    _router.routerDelegate.addListener(whenBooted);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _links?.cancel();
    _updates.removeListener(_onUpdate);
    _router.routerDelegate.removeListener(_checkWhenSettled);
    _updates.dispose();
    disposeDependencies();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<Preferences>.value(value: services.prefs),
        ChangeNotifierProvider<SessionSelection>.value(
          value: services.selection,
        ),
        ChangeNotifierProvider<BackedUpOwnerIdentityStore>.value(
          value: services.identityStore,
        ),
        ChangeNotifierProvider<Hosts>.value(value: services.hosts),
      ],
      // Theme is reactive: toggling the mode in Settings notifies
      // [Preferences] → this Consumer rebuilds → MaterialApp swaps theme.
      child: Consumer<Preferences>(
        builder: (context, prefs, _) => MaterialApp.router(
          title: kAppName,
          locale: appLocale = prefs.language == null
              ? null
              : Locale(prefs.language!),
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: prefs.themeMode,
          routerConfig: _router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          debugShowCheckedModeBanner: false,
          // User-chosen text size. Applied here rather than by
          // scaling `AppTypography`'s base sizes so the many per-widget
          // `copyWith(fontSize: …)` overrides scale too. `TextScaler.linear`
          // REPLACES the platform scaler, which is deliberate: Flutter can't
          // read a per-app text size anyway (it only reads the global
          // accessibility setting), so honoring both would compound them.
          builder: (context, child) => MediaQuery.withClampedTextScaling(
            minScaleFactor: prefs.fontScale.factor,
            maxScaleFactor: prefs.fontScale.factor,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
