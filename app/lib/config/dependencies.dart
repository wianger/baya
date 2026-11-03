import 'dart:io' show Platform;

import 'package:app/data/hosts/hosts.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/session_files/session_files_repository.dart';
import 'package:app/data/transport/host_socket.dart';
import 'package:app/data/update/secure_dismissed_update_store.dart';
import 'package:app/data/update/update_checker_impl.dart';
import 'package:app/data/update/url_launcher_opener.dart';
import 'package:app/data/voice/speech_service.dart';
import 'package:app/data/workspaces/workspace_repository.dart';
import 'package:app/domain/session_files/session_files_repository.dart';
import 'package:app/domain/workspaces/workspace_repository.dart';
import 'package:app/pairing/backed_up_identity_store.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
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
}

final class AppServices {
  AppServices._(this.prefs, this._packageInfo);

  final Preferences prefs;
  final PackageInfo _packageInfo;

  // ── Infrastructure ────────────────────────────────────────────────────
  late final storage = PairingStorage();

  /// The owner key: kept on this phone, backed up to Block Store when
  /// Google Backup allows it.
  late final identityStore = BackedUpOwnerIdentityStore(
    MethodChannelOwnerIdentityStore(),
  );
  late final ownerBridge = OwnerIdentityBridge(identityStore, storage);

  /// Every paired computer, each kept connected.
  late final hosts = Hosts(
    storage: storage,
    connect: WsHostSocket.connect,
    identity: ownerBridge.requireKeyPair,
  );
  // Owns a broadcast sound-level stream that outlives chat screens.
  late final SpeechService speech = SpeechToTextService();
  late final IImagePickerService imagePicker = ImagePickerService();

  // ── App-wide UI state ─────────────────────────────────────────────────
  /// The session the tablet detail pane shows; starts empty.
  late final selection = SessionSelection();
  late final shellLayout = ShellLayout();

  // ── Data ──────────────────────────────────────────────────────────────
  late final IWorkspaceRepository workspaces = WorkspaceRepository(hosts);
  late final ISessionFilesRepository sessionFiles = SessionFilesRepository(
    hosts,
    selection,
  );

  // ── ViewModels: a new instance per screen ─────────────────────────────
  late final Map<Type, ViewModel Function()> _viewModels = {
    NewSessionViewModel: () => NewSessionViewModel(workspaces),
    SessionFilesViewModel: () => SessionFilesViewModel(sessionFiles),
    HomeViewModel: () => HomeViewModel(hosts, storage, prefs),
    SettingsViewModel: () => SettingsViewModel(storage, prefs, hosts),
    PairingViewModel: () =>
        PairingViewModel(storage, WsHostSocket.connect, prefs, ownerBridge),
    OnboardingViewModel: () => OnboardingViewModel(prefs),
    VoiceInputViewModel: () => VoiceInputViewModel(speech),
    AttachmentViewModel: () => AttachmentViewModel(imagePicker),
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
    hosts.dispose();
    speech.dispose();
  }
}

void disposeDependencies() => services.dispose();

/// A fresh `ViewModel<T>` from the composition root on each route mount.
class ViewmodelProvider<T extends ViewModel> extends ChangeNotifierProvider<T> {
  ViewmodelProvider({super.key, super.child})
    : super(create: (_) => services.viewModel<T>());

  ViewmodelProvider.value({super.key, required super.value, super.child})
    : super.value();
}
