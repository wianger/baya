import 'package:app/ui/core/branding/app_brand.dart';
import 'package:app/config/dependencies.dart';
import 'package:app/data/local/boxes.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/routing/app_router.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/themes/app_font_licenses.dart';
import 'package:app/l10n/l10n.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerAppFontLicenses();
  // Open the v2 SSOT boxes + WIPE the volatile runtime box BEFORE
  // anything subscribes (#3 / Risk 2).
  await LocalBoxes.init();
  await setupDependencies();
  // Eagerly construct the SSOT writer so it's consuming the channel from boot
  // (messages can arrive before the chat screen mounts).
  services.sync;
  runApp(const RemotePiApp());
}

class RemotePiApp extends StatefulWidget {
  const RemotePiApp({super.key});

  @override
  State<RemotePiApp> createState() => _RemotePiAppState();
}

class _RemotePiAppState extends State<RemotePiApp> with WidgetsBindingObserver {
  late final _router = buildRouter(
    services.storage,
    services.connection,
    services.prefs,
    services.ownerBridge,
    services.meshSync,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    disposeDependencies();
    super.dispose();
  }

  /// Keep the mesh poll timer aligned with the app's
  /// foreground lifecycle. Polling runs ONLY while resumed; in
  /// inactive/paused/hidden/detached we cancel so we don't drain the
  /// battery (and we'll resync via `pullOnDemand` on the next resume +
  /// boot path).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final meshSync = services.meshSync;
    switch (state) {
      case AppLifecycleState.resumed:
        meshSync.startPolling();
        // ignore: unawaited_futures
        meshSync.pullOnDemand();
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        meshSync.stopPolling();
    }
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
        // into a single centered pane on zero-state Home (no Pi / empty).
        ChangeNotifierProvider<ShellLayout>.value(value: services.shellLayout),
      ],
      // Theme is reactive: toggling the mode in Settings notifies
      // [Preferences] → this Consumer rebuilds → MaterialApp swaps theme.
      child: DynamicColorBuilder(
        builder: (lightDynamic, darkDynamic) => Consumer<Preferences>(
          builder: (context, prefs, _) => MaterialApp.router(
            title: kAppName,
            theme: buildLightTheme(lightDynamic),
            darkTheme: buildDarkTheme(darkDynamic),
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
      ),
    );
  }
}
