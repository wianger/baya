import 'package:app/config/dependencies.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/hosts/hosts.dart';
import 'package:app/data/hosts/session_controller.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/core/widgets/baya_motion.dart';
import 'package:app/ui/workspaces/session_shell.dart';
import 'package:app/ui/workspaces/new_session_page.dart';
import 'package:app/ui/about/about_page.dart';
import 'package:app/ui/workspaces/viewmodels/new_session_viewmodel.dart';
import 'package:app/ui/workspaces/states/new_session_state.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/onboarding/onboarding_page.dart';
import 'package:app/ui/onboarding/viewmodels/onboarding_viewmodel.dart';
import 'package:app/ui/pairing/pairing_page.dart';
import 'package:app/ui/pairing/viewmodels/pairing_viewmodel.dart';
import 'package:app/ui/settings/settings_page.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:app/ui/session_files/session_files_page.dart';
import 'package:app/ui/session_files/viewmodels/session_files_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

// Boot decision is async — _BootState is a ChangeNotifier used as
// refreshListenable so the router redirects once the storage check finishes.
class _BootState extends ChangeNotifier {
  bool _ready = false;
  bool _hasPeer = false;
  bool _onboarded = false;
  bool _identityWasGenerated = false;

  bool get ready => _ready;
  bool get hasPeer => _hasPeer;
  bool get onboarded => _onboarded;

  /// True when this run is the very first time the Owner key materialised
  /// on this account (the bridge just generated it). Restored identities
  /// — anything coming back from Block Store, including
  /// the "reinstalled the app on the same device" case where the platform
  /// re-hands the previous key — set this to false.
  ///
  /// Drives the redirect: only fresh identities **and** an empty peer
  /// list get sent to the onboarding stepper; everything else lands on
  /// /home (which itself shows a friendly "pair your first computer" state
  /// when peers is empty).
  bool get identityWasGenerated => _identityWasGenerated;

  Future<void> load(
    PairingStorage storage,
    Hosts hosts,
    Preferences prefs,
    OwnerIdentityBridge ownerBridge, {
    void Function()? installWatcherAfterBoot,
  }) async {
    await prefs.load();

    // The owner key always lives on this phone; Block Store only backs
    // it up, so boot never blocks on Google Backup.
    final ownerResult = await ownerBridge.boot();
    _identityWasGenerated = ownerResult.generated;

    // Install the platform-sync watcher *after* boot completes so its
    // initial-emit race (see OwnerIdentityBridge.startWatching) can't
    // ever observe a null _current. The bridge has its own defence
    // for the null case; this is the belt to its suspenders.
    installWatcherAfterBoot?.call();

    final peers = await storage.listPeers();
    _hasPeer = peers.isNotEmpty;
    _onboarded = prefs.onboardingCompleted;
    _ready = true;
    notifyListeners();
    // Connect to every paired computer.
    await hosts.start();
  }

  /// Invoked by the OwnerIdentityBridge watch listener when
  /// platform sync delivers a different Owner-pk. We reset to the
  /// "no-state" view; the next `load()` call (triggered when the user
  /// returns to /boot) will repopulate from the freshly-wiped storage.
  void onOwnerKeyReplaced() {
    _ready = false;
    _hasPeer = false;
    _onboarded = false;
    notifyListeners();
  }
}

GoRouter buildRouter(
  PairingStorage storage,
  Hosts hosts,
  Preferences prefs,
  OwnerIdentityBridge ownerBridge,
) {
  final boot = _BootState();

  // Watch for Owner-key drift on the sync surface. When the
  // platform delivers a different keypair (restored on a new device,
  // user wiped and re-installed elsewhere), the bridge wipes peers and session lists
  // and we reset the boot state so the router redirects through /boot.
  //
  // Hook is captured here but only installed AFTER boot() succeeds —
  // see _BootState.load's `installWatcherAfterBoot` parameter. That
  // ordering matters: the platform plugin emits an initial blob the
  // moment we subscribe; we must have `_current` populated by boot()
  // first, otherwise the bridge would see "different owner_pk" (vs
  // null) and wipe the freshly-loaded peer set.
  var watcherInstalled = false;
  void installWatcher() {
    if (watcherInstalled) return;
    watcherInstalled = true;
    ownerBridge.startWatching(
      onReset: () async {
        boot.onOwnerKeyReplaced();
        await boot.load(storage, hosts, prefs, ownerBridge);
      },
    );
  }

  boot.load(
    storage,
    hosts,
    prefs,
    ownerBridge,
    installWatcherAfterBoot: installWatcher,
  );

  return GoRouter(
    initialLocation: '/boot',
    refreshListenable: boot,
    redirect: (context, state) {
      if (!boot.ready) return '/boot';
      // Onboarding stepper only runs on a truly fresh install — when
      // the Owner key was generated this run AND there is no
      // membership to inherit. Restored identities (Block Store handed
      // us back the key, including the
      // "reinstalled on the same device" case) skip straight to home,
      // even if peers are empty. Home has a first-pair empty state
      // that covers that case more cleanly than re-running the welcome
      // wizard a second time.
      final shouldOnboard = boot.identityWasGenerated && !boot.hasPeer;
      final target = shouldOnboard ? '/onboarding' : '/home';
      if (state.uri.path == '/boot') {
        return target;
      }
      return null;
    },
    routes: [
      // Splash while boot.load() is in flight
      GoRoute(path: '/boot', builder: (ctx, st) => const _BootSplash()),

      GoRoute(
        path: '/new-session',
        builder: (ctx, st) {
          final extra = st.extra;
          return ChangeNotifierProvider<NewSessionViewModel>(
            create: (_) => NewSessionViewModel(
              services.workspaces,
              launch: extra is NewSessionLaunch
                  ? extra
                  : const NewSessionLaunch(),
            ),
            child: const NewSessionPage(),
          );
        },
      ),
      // QR pairing flow
      GoRoute(
        path: '/pair',
        builder: (ctx, st) => ViewmodelProvider<PairingViewModel>(
          child: PairingPage(
            initialCode: st.extra is String ? st.extra as String : null,
          ),
        ),
      ),

      // Onboarding — 3-step flow shown when the app has
      // never been paired AND the user hasn't opted out. Provides
      // both OnboardingViewModel (state machine) AND PairingViewModel
      // (step 3 embeds the QR scanner reusing existing pair flow).
      GoRoute(
        path: '/onboarding',
        builder: (ctx, st) => MultiProvider(
          providers: [
            ViewmodelProvider<OnboardingViewModel>(),
            ViewmodelProvider<PairingViewModel>(),
          ],
          child: const OnboardingPage(),
        ),
      ),

      // Home, a chat and its files share one shell: the sidebar (tablets)
      // or drawer (phones) stays put while the pane beside it fades through
      // from one to the next.
      ShellRoute(
        builder: (ctx, st, child) =>
            ViewmodelProvider<HomeViewModel>(child: SessionShell(child: child)),
        routes: [
          GoRoute(
            path: '/home',
            pageBuilder: (ctx, st) =>
                _fadeThrough(st.pageKey, const SessionWelcome()),
          ),
          GoRoute(
            path: '/session-files',
            pageBuilder: (ctx, st) => _fadeThrough(
              st.pageKey,
              ViewmodelProvider<SessionFilesViewModel>(
                child: const SessionFilesPage(),
              ),
            ),
          ),
          // The selected session. Its page is keyed by the session, so
          // opening another fades through to a page with its own
          // controller, and the one left behind closes with `session/close`.
          GoRoute(
            path: '/chat',
            pageBuilder: (ctx, st) {
              final extra = st.extra;
              final selection = ctx.watch<SessionSelection>().current;
              final host = hosts.byKey(selection?.hostKey);
              if (selection == null || host == null) {
                return _fadeThrough(
                  const ValueKey('chat-none'),
                  const SessionWelcome(),
                );
              }
              return _fadeThrough(
                ValueKey('chat-${selection.hostKey}-${selection.sessionId}'),
                MultiProvider(
                  providers: [
                    ChangeNotifierProvider<SessionController>(
                      create: (_) =>
                          SessionController(host, selection.sessionId),
                    ),
                    ViewmodelProvider<VoiceInputViewModel>(),
                    ViewmodelProvider<AttachmentViewModel>(),
                  ],
                  child: ChatPage(
                    initialTitle: extra is Map
                        ? extra['title'] as String?
                        : selection.title,
                    initialDevice: extra is Map
                        ? extra['device'] as String?
                        : selection.device,
                    initialOnline: extra is Map
                        ? extra['online'] == true
                        : selection.online,
                    showBack: false,
                  ),
                ),
              );
            },
          ),
        ],
      ),

      // Settings (entered from /home menu)
      GoRoute(
        path: '/settings',
        builder: (ctx, st) => MultiProvider(
          providers: [
            ViewmodelProvider<SettingsViewModel>(),
            ViewmodelProvider<UpdateBannerViewModel>(),
          ],
          child: const SettingsPage(),
        ),
      ),
      GoRoute(
        path: '/about',
        builder: (ctx, st) => MultiProvider(
          providers: [ViewmodelProvider<UpdateBannerViewModel>()],
          child: const AboutPage(),
        ),
      ),
    ],
  );
}

Page<void> _fadeThrough(LocalKey key, Widget child) => CustomTransitionPage(
  key: key,
  child: child,
  transitionDuration: BayaMotion.emphasized,
  reverseTransitionDuration: BayaMotion.standard,
  transitionsBuilder: bayaFadeThrough,
);

class _BootSplash extends StatelessWidget {
  const _BootSplash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.bg,
      body: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            color: context.colors.accent,
            strokeWidth: 2,
          ),
        ),
      ),
    );
  }
}
