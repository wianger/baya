import 'package:app/config/dependencies.dart';
import 'package:app/data/mesh/mesh_sync_service.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/commands/viewmodels/agent_commands_viewmodel.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/quick_actions/viewmodels/quick_actions_viewmodel.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/core/themes/themes.dart';
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
import 'package:app/ui/sync_required/sync_required_page.dart';
import 'package:flutter/material.dart';
import 'package:app/ui/chat/context/viewmodels/context_usage_viewmodel.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

// Boot decision is async — _BootState is a ChangeNotifier used as
// refreshListenable so the router redirects once the storage check finishes.
class _BootState extends ChangeNotifier {
  bool _ready = false;
  bool _hasPeer = false;
  bool _onboarded = false;
  bool _syncAvailable = true;
  bool _identityWasGenerated = false;

  bool get ready => _ready;
  bool get hasPeer => _hasPeer;
  bool get onboarded => _onboarded;
  bool get syncAvailable => _syncAvailable;

  /// True when this run is the very first time the Owner key materialised
  /// on this account (the bridge just generated it). Restored identities
  /// — anything coming back from iCloud Keychain / Block Store, including
  /// the "reinstalled the app on the same device" case where the platform
  /// re-hands the previous key — set this to false.
  ///
  /// Drives the redirect: only fresh identities **and** an empty peer
  /// list get sent to the onboarding stepper; everything else lands on
  /// /home (which itself shows a friendly "pair your first Pi" state
  /// when peers is empty).
  bool get identityWasGenerated => _identityWasGenerated;

  Future<void> load(
    PairingStorage storage,
    ConnectionManager conn,
    Preferences prefs,
    OwnerIdentityBridge ownerBridge,
    MeshSyncService meshSync, {
    void Function()? installWatcherAfterBoot,
  }) async {
    await prefs.load();

    // Plan 23 — block bootstrap until the platform's key-sync surface
    // (iCloud Keychain / Block Store) is usable AND we have an
    // Owner-key (loaded or freshly generated). If sync is off, the
    // router redirects to /sync-required and the user retries from
    // there once they flip the toggle in Settings.
    final ownerResult = await ownerBridge.boot();
    if (ownerResult is SyncUnavailableResult) {
      _syncAvailable = false;
      _ready = true;
      notifyListeners();
      return;
    }
    _syncAvailable = true;
    _identityWasGenerated =
        ownerResult is IdentityReady && ownerResult.generated;

    // Install the platform-sync watcher *after* boot completes so its
    // initial-emit race (see OwnerIdentityBridge.startWatching) can't
    // ever observe a null _current. The bridge has its own defence
    // for the null case; this is the belt to its suspenders.
    installWatcherAfterBoot?.call();

    // Plan 24 — pull mesh_versions from the relay BEFORE listing peers
    // so a reinstall on a new device materialises the same membership
    // the user had on the old one. Failure (offline, relay down, 4xx)
    // is logged inside the service and we fall back gracefully on the
    // local cache.
    await meshSync.pullOnDemand();

    final peers = await storage.listPeers();
    _hasPeer = peers.isNotEmpty;
    // Plan 14: a user who already has a peer is implicitly onboarded —
    // they paired in an earlier app version that predates the
    // onboarding flow. Auto-flip the flag so they don't re-run it.
    if (_hasPeer && !prefs.onboardingCompleted) {
      await prefs.setOnboardingCompleted(true);
    }
    _onboarded = prefs.onboardingCompleted;
    _ready = true;
    notifyListeners();
    // Plano 13: `Preferences.selectedPeerEpk` is the authoritative
    // pointer to the peer the user wants connected. On a fresh install
    // it's null — default to `peers.first` so subsequent boot()s have a
    // stable target and the user lands on a deterministic chat.
    if (_hasPeer) {
      var selected = prefs.selectedPeerEpk;
      if (selected == null) {
        selected = peers.first.remoteEpk;
        await prefs.setSelectedPeerEpk(selected);
      } else if (!peers.any((p) => p.remoteEpk == selected)) {
        // Selected peer was revoked / no longer in storage — fall back.
        selected = peers.first.remoteEpk;
        await prefs.setSelectedPeerEpk(selected);
      }
      // ignore: unawaited_futures
      conn.boot(preferredEpk: selected);
    }
  }

  /// Plan 23 — invoked by the OwnerIdentityBridge watch listener when
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
  ConnectionManager conn,
  Preferences prefs,
  OwnerIdentityBridge ownerBridge,
  MeshSyncService meshSync,
) {
  final boot = _BootState();

  // Plan 23 — watch for Owner-key drift on the sync surface. When the
  // platform delivers a different keypair (restored on a new device,
  // user wiped and re-installed elsewhere), the bridge wipes peers/rooms
  // and we reset the boot state so the router redirects through /boot.
  // Plan 24 — reset the mesh version watermark too, otherwise the
  // first fetch against the new Owner-pk would use a stale `since`.
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
        await conn.disconnect();
        meshSync.resetVersionWatermark();
        boot.onOwnerKeyReplaced();
        await boot.load(storage, conn, prefs, ownerBridge, meshSync);
      },
    );
  }

  boot.load(
    storage,
    conn,
    prefs,
    ownerBridge,
    meshSync,
    installWatcherAfterBoot: installWatcher,
  );

  // Plan 24 — start foreground polling. The router doesn't have
  // direct access to AppLifecycleState; main.dart wires
  // [MeshSyncService.startPolling/stopPolling] to the lifecycle so
  // this initial start covers the "app launched in foreground" case.
  meshSync.startPolling();

  return GoRouter(
    initialLocation: '/boot',
    refreshListenable: boot,
    redirect: (context, state) {
      if (!boot.ready) return '/boot';
      // Sync-required gate is sticky until the user toggles iCloud /
      // Backup on and taps "Check again". Don't redirect away from
      // /sync-required while the bridge still reports unavailable.
      if (!boot.syncAvailable) {
        return state.uri.path == '/sync-required' ? null : '/sync-required';
      }
      // Onboarding stepper only runs on a truly fresh install — when
      // the Owner key was generated this run AND there is no
      // membership to inherit. Restored identities (iCloud Keychain /
      // Block Store handed us back the key, including the
      // "reinstalled on the same device" case) skip straight to home,
      // even if peers are empty. Home has a first-pair empty state
      // that covers that case more cleanly than re-running the welcome
      // wizard a second time.
      final shouldOnboard = boot.identityWasGenerated && !boot.hasPeer;
      final target = shouldOnboard ? '/onboarding' : '/home';
      if (state.uri.path == '/sync-required' || state.uri.path == '/boot') {
        return target;
      }
      return null;
    },
    routes: [
      // Splash while boot.load() is in flight
      GoRoute(path: '/boot', builder: (ctx, st) => const _BootSplash()),

      // Plan 23 — first-launch gate when iCloud Keychain / Google
      // Backup is off. Sticky route: redirect keeps the user here
      // until the bridge reports sync available.
      GoRoute(
        path: '/sync-required',
        builder: (ctx, st) => const SyncRequiredPage(),
      ),

      GoRoute(
        path: '/home',
        builder: (ctx, st) => ViewmodelProvider<HomeViewModel>(
          child: const SessionShell(child: SessionWelcome()),
        ),
      ),
      GoRoute(
        path: '/new-session',
        builder: (ctx, st) {
          final extra = st.extra;
          return ChangeNotifierProvider<NewSessionViewModel>(
            create: (_) => NewSessionViewModel(
              injector.get<IWorkspaceRepository>(),
              launch: extra is NewSessionLaunch
                  ? extra
                  : const NewSessionLaunch(),
            ),
            child: const NewSessionPage(),
          );
        },
      ),
      GoRoute(
        path: '/session-files',
        builder: (ctx, st) => MultiProvider(
          providers: [
            ViewmodelProvider<HomeViewModel>(),
            ViewmodelProvider<SessionFilesViewModel>(),
          ],
          child: const SessionShell(child: SessionFilesPage()),
        ),
      ),

      // QR pairing flow
      GoRoute(
        path: '/pair',
        builder: (ctx, st) =>
            ViewmodelProvider<PairingViewModel>(child: const PairingPage()),
      ),

      // Onboarding (plan 14) — 3-step flow shown when the app has
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

      // Chat screen — PHONE full-screen path (root navigator, above the
      // shell), so it keeps native back/swipe. On tablet the chat lives
      // in the detail branch instead (see _detailPane). Entered by
      // tapping a session in /home.
      // Plan/24-fix-title: Home passes the already-known peer label
      // (nickname / sessionName) via `extra` so the AppBar renders
      // the right title from frame 1 instead of waiting for the
      // first `room_meta_updated` to arrive. Keeps reactivity to
      // room metadata changes that come later through the
      // ChatViewModel.
      GoRoute(
        path: '/chat',
        builder: (ctx, st) {
          final extra = st.extra;
          String? initialTitle;
          String? initialDevice;
          var initialOnline = false;
          if (extra is Map) {
            final t = extra['title'];
            if (t is String && t.isNotEmpty) initialTitle = t;
            // Plan/32g — device (Mac) label Home already knows, so AppBar
            // line 2 renders immediately (no async PeerRecord wait).
            final d = extra['device'];
            if (d is String && d.isNotEmpty) initialDevice = d;
            // Live state of the tile → initial status dot (no reconnect flash).
            initialOnline = extra['online'] == true;
          }
          final selection = ctx.watch<SessionSelection>().current;
          return MultiProvider(
            key: ValueKey('chat-${selection?.epk}-${selection?.roomId}'),
            providers: [
              ViewmodelProvider<HomeViewModel>(),
              ViewmodelProvider<ChatViewModel>(),
              ViewmodelProvider<QuickActionsViewModel>(),
              ViewmodelProvider<AgentCommandsViewModel>(),
              ViewmodelProvider<ContextUsageViewModel>(),
              ViewmodelProvider<VoiceInputViewModel>(),
              ViewmodelProvider<AttachmentViewModel>(),
            ],
            child: SessionShell(
              child: ChatPage(
                initialTitle: initialTitle,
                initialDevice: initialDevice,
                initialOnline: initialOnline,
                showBack: false,
              ),
            ),
          );
        },
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
