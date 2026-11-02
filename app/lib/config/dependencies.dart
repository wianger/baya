import 'dart:async';
import 'dart:io' show Platform;

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/commands/agent_commands_repository.dart';
import 'package:app/data/context/context_usage_repository.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/local/boxes.dart';
import 'package:app/data/mesh/mesh_client.dart';
import 'package:app/data/mesh/mesh_sync_service.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/repositories/home_read_repository.dart';
import 'package:app/data/repositories/session_read_repository.dart';
import 'package:app/data/session_files/session_files_repository.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/channel.dart'; // IChannel
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/data/transport/relay_config.dart';
import 'package:app/data/transport/ws_transport.dart';
import 'package:app/data/update/secure_dismissed_update_store.dart';
import 'package:app/data/update/update_checker_impl.dart';
import 'package:app/data/update/url_launcher_opener.dart';
import 'package:app/data/voice/speech_service.dart';
import 'package:app/data/workspaces/workspace_repository.dart';
import 'package:app/domain/contracts/agent_commands_repository.dart';
import 'package:app/domain/contracts/context_usage_repository.dart';
import 'package:app/domain/session_files/session_files_repository.dart';
import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/pairing/qr_scanner.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/commands/viewmodels/agent_commands_viewmodel.dart';
import 'package:app/ui/chat/context/viewmodels/context_usage_viewmodel.dart';
import 'package:app/ui/chat/quick_actions/viewmodels/quick_actions_viewmodel.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:app/ui/onboarding/viewmodels/onboarding_viewmodel.dart';
import 'package:app/ui/pairing/viewmodels/pairing_viewmodel.dart';
import 'package:app/ui/session_files/viewmodels/session_files_viewmodel.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:app/ui/workspaces/viewmodels/new_session_viewmodel.dart';
import 'package:baya_identity/baya_identity.dart';
import 'package:cryptography/cryptography.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

/// The app's composition root.
///
/// Every dependency is a typed field, so wiring mistakes are compile errors
/// rather than failed runtime lookups. `late final` keeps singletons lazy:
/// each one is built the first time something reads it.
late final AppServices services;

Future<void> setupDependencies() async {
  final prefs = Preferences();
  await prefs.load();
  final packageInfo = await PackageInfo.fromPlatform();
  services = AppServices._(prefs, packageInfo);
  services.storage.attachPeerMutationHook(() {
    // ignore: unawaited_futures
    services.meshSync.publish();
  });
}

final class AppServices {
  AppServices._(this.prefs, this._packageInfo);

  final Preferences prefs;
  final PackageInfo _packageInfo;

  // ── Infrastructure ────────────────────────────────────────────────────
  late final storage = PairingStorage();
  // Boxes are opened and the runtime box wiped in bootstrap before this.
  late final boxes = LocalBoxes();
  late final ownerBridge = OwnerIdentityBridge(
    MethodChannelOwnerIdentityStore(),
    storage,
  );
  // The relay's `/mesh` endpoint shares host and port with the WebSocket.
  late final meshClient = MeshClient(
    baseUrlProvider: () => resolveRelayUrl(prefs),
  );
  late final meshSync = MeshSyncService(meshClient, ownerBridge, storage);
  late final connection = ConnectionManager(
    factory: _productionConnectionFactory,
    storage: storage,
  );
  // Owns a broadcast sound-level stream that outlives chat screens.
  late final SpeechService speech = SpeechToTextService();
  late final IImagePickerService imagePicker = ImagePickerService();

  // ── Data ──────────────────────────────────────────────────────────────
  /// The single writer of the message, index and runtime boxes.
  late final sync = SyncService(
    connection,
    boxes,
    isSessionHidden: prefs.isSessionHidden,
  );
  late final sessionReads = SessionReadRepository(boxes);
  late final homeReads = HomeReadRepository(boxes);
  late final IActionsRepository actions = ActionsRepository(connection);
  late final IAgentCommandsRepository agentCommands = AgentCommandsRepository(
    connection,
  );
  late final IContextUsageRepository contextUsage = ContextUsageRepository(
    connection,
  );
  late final IWorkspaceRepository workspaces = WorkspaceRepository(
    connection,
    storage,
    prefs,
  );
  late final ISessionFilesRepository sessionFiles = SessionFilesRepository(
    connection,
  );

  // ── App-wide UI state ─────────────────────────────────────────────────
  /// The session the tablet detail pane shows; starts empty.
  late final selection = SessionSelection();
  late final shellLayout = ShellLayout();

  // ── ViewModels: a new instance per screen ─────────────────────────────
  late final Map<Type, ViewModel Function()> _viewModels = {
    ContextUsageViewModel: () => ContextUsageViewModel(contextUsage),
    NewSessionViewModel: () => NewSessionViewModel(workspaces),
    SessionFilesViewModel: () => SessionFilesViewModel(sessionFiles),
    ChatViewModel: () =>
        ChatViewModel(sessionReads, sync, connection, prefs, storage),
    HomeViewModel: () =>
        HomeViewModel(storage, prefs, connection, sync, meshSync, actions),
    SettingsViewModel: () =>
        SettingsViewModel(storage, prefs, connection, meshSync),
    PairingViewModel: () => PairingViewModel(
      storage,
      _productionPairingTransportFactory,
      connection,
      prefs,
      ownerBridge,
    ),
    OnboardingViewModel: () => OnboardingViewModel(prefs),
    QuickActionsViewModel: () => QuickActionsViewModel(actions),
    AgentCommandsViewModel: () => AgentCommandsViewModel(agentCommands),
    VoiceInputViewModel: () => VoiceInputViewModel(speech),
    AttachmentViewModel: () => AttachmentViewModel(imagePicker, actions),
    UpdateBannerViewModel: () => UpdateBannerViewModel(
      UpdateCheckerImpl(),
      SecureDismissedUpdateStore(),
      const UrlLauncherOpener(),
      currentVersion: _packageInfo.version,
      currentBuildNumber: int.tryParse(_packageInfo.buildNumber) ?? 0,
      enabled: Platform.isAndroid,
    ),
  };

  T viewModel<T extends ViewModel>() => _viewModels[T]!() as T;

  void dispose() {
    sync.dispose();
    connection.dispose();
    speech.dispose();
  }
}

// ---------------------------------------------------------------------------
// Production ConnectionFactory — used by ConnectionManager for reconnection.
// Owner-sk (synced via Block Store) is the
// challenge-response key. OwnerIdentityBridge.boot() is the router's
// responsibility; by the time this factory runs, the identity is loaded.
// ---------------------------------------------------------------------------

Future<IChannel> _productionConnectionFactory(
  PeerRecord peer,
  CancelToken cancel,
) async {
  final ownerKey = await services.ownerBridge.requireKeyPair();
  if (cancel.isCancelled) throw _CancelledError();

  // Defensive timeout: without this the
  // WebSocket connect + Ed25519 challenge round-trip can hang
  // indefinitely if the relay is unreachable — ChatViewModel would sit
  // in `ChatConnecting` forever. Throwing here pushes the manager into
  // its retry/backoff path, which is observable as `StatusRetrying` and
  // renders a "reconnecting" banner rather than an empty spinner.
  const wsConnectTimeout = Duration(seconds: 10);
  // One relay for every peer: the QR-adopted or Settings URL, else default.
  final relayUrl = resolveRelayUrl(services.prefs);
  final transport =
      await WsTransport.connect(
        relayUrl: relayUrl,
        peerPubkey: peer.remoteEpk,
        ed25519Key: ownerKey,
      ).timeout(
        wsConnectTimeout,
        onTimeout: () => throw TimeoutException(
          'WS connect to $relayUrl timed out after '
          '${wsConnectTimeout.inSeconds}s',
        ),
      );

  if (cancel.isCancelled) {
    await transport.close();
    throw _CancelledError();
  }

  return PlainPeerChannel(transport: transport);
}

// ---------------------------------------------------------------------------
// Production PairingTransportFactory — used by PairingViewModel for first pair.
// ---------------------------------------------------------------------------

Future<PeerTransport> _productionPairingTransportFactory(
  QrPairPayload qr,
  SimpleKeyPair deviceEd25519,
) async {
  return WsTransport.connect(
    relayUrl: qr.relayUrl,
    peerPubkey: qr.epk,
    ed25519Key: deviceEd25519,
  );
}

// ---------------------------------------------------------------------------

class _CancelledError implements Exception {
  const _CancelledError();
}

void disposeDependencies() => services.dispose();

/// A fresh `ViewModel<T>` from the composition root on each route mount.
class ViewmodelProvider<T extends ViewModel> extends ChangeNotifierProvider<T> {
  ViewmodelProvider({super.key, super.child})
    : super(create: (_) => services.viewModel<T>());

  ViewmodelProvider.value({super.key, required super.value, super.child})
    : super.value();
}
