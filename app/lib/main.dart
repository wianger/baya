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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Includes the link that cold-started the app.
    _links = AppLinks().uriLinkStream.listen(_openLink);
  }

  /// Back in the foreground: reconnect now instead of waiting out a backoff.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) services.hosts.reconnectAll();
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
        // Shell layout state — lets the adaptive shell collapse the split
        // into a single centered pane on zero-state Home (no computer / empty).
        ChangeNotifierProvider<BackedUpOwnerIdentityStore>.value(
          value: services.identityStore,
        ),
        ChangeNotifierProvider<ShellLayout>.value(value: services.shellLayout),
        ChangeNotifierProvider<Hosts>.value(value: services.hosts),
      ],
      // Theme is reactive: toggling the mode in Settings notifies
      // [Preferences] → this Consumer rebuilds → MaterialApp swaps theme.
      child: Consumer<Preferences>(
        builder: (context, prefs, _) => MaterialApp.router(
          title: kAppName,
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
