import 'package:app/domain/contracts/dismissed_update_store.dart';
import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/contracts/url_opener.dart';
import 'package:app/domain/entities/update_info.dart';
import 'package:app/domain/value_objects/semver.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/update/states/update_banner_state.dart';

/// Aviso de atualização in-app, **Android-only** (plano 44, passo 3 — espelho
/// do passo 7 do plano 43 do Cockpit). No [check] (disparado no mount da Home,
/// = startup) consulta o manifest; se houver versão **maior** que a atual e que
/// **não foi dispensada**, emite [UpdateBannerVisible]. Tudo best-effort:
/// falhas são silenciosas.
///
/// O gate de plataforma vive aqui via [enabled] (injetado como
/// `Platform.isAndroid` no boot) — isso mantém a regra "nada no iOS"
/// testável sem depender do host onde o `flutter test` roda.
class UpdateBannerViewModel extends ViewModel<UpdateBannerState> {
  UpdateBannerViewModel(
    this._checker,
    this._dismissed,
    this._opener, {
    required this.currentVersion,
    required this.enabled,
    this.currentBuildNumber = 0,
    this.platform = 'android',
    this.format = 'apk',
    this.arch = 'universal',
    this.fallbackUrl = _kFallbackUrl,
  }) : super(const UpdateBannerHidden());

  final UpdateChecker _checker;
  final DismissedUpdateStore _dismissed;
  final UrlOpener _opener;

  /// Versão do app rodando (de `package_info`, injetada no boot).
  final String currentVersion;
  final int currentBuildNumber;

  /// `true` só no Android — em iOS o app atualiza pela App Store, então o
  /// aviso nunca aparece.
  final bool enabled;

  /// Coordenadas do artefato a baixar (Android = apk universal).
  final String platform;
  final String format;
  final String arch;

  /// Página de download do site — fallback quando não há artefato compatível.
  final String fallbackUrl;

  static const String _kFallbackUrl =
      'https://github.com/wianger/baya/releases';

  bool _checked = false;
  bool _disposed = false;

  /// Consulta o manifest e decide se o card deve aparecer. Silencioso em
  /// falha. Idempotente por instância (re-mount cria nova instância e
  /// re-consulta; uma mesma instância só consulta uma vez).
  Future<void> check() async {
    if (!enabled) return; // iOS / não-Android → nunca mostra.
    if (_checked) return;
    _checked = true;

    final latest = await _checker.fetchLatest();
    if (_disposed) return;
    if (latest == null) return; // sem rede/manifest/inválido → nada.
    if (!_isNewer(latest)) {
      return; // igual/menor → nada.
    }

    final dismissed = await _dismissed.dismissedVersion();
    if (_disposed) return;
    if (dismissed == latest.version) return; // dispensada → nada.

    emit(UpdateBannerVisible(latest));
  }

  bool _isNewer(UpdateInfo info) {
    if (info.buildNumber > 0 && currentBuildNumber > 0) {
      return info.buildNumber > currentBuildNumber &&
          compareSemver(info.version, currentVersion) >= 0;
    }
    return isNewerVersion(info.version, currentVersion);
  }

  /// Manual checks bypass dismissal and report network/API failures visibly.
  Future<void> checkManually() async {
    if (!enabled || state is UpdateCheckInProgress) return;
    emit(const UpdateCheckInProgress());
    final latest = await _checker.fetchLatest();
    if (_disposed) return;
    if (latest == null) {
      emit(
        const UpdateCheckFailed(
          'Could not check GitHub. Check your connection and try again.',
        ),
      );
    } else if (_isNewer(latest)) {
      emit(UpdateBannerVisible(latest));
    } else {
      emit(const UpdateCheckCurrent());
    }
  }

  Future<bool> openReleases() => _opener.open(fallbackUrl);

  /// Open an arbitrary external link through the same platform opener the
  /// update flow uses, so About/markdown links share one error path.
  Future<bool> openUrl(String url) => _opener.open(url);

  /// Fecha o card e persiste a versão como dispensada — não reaparece pra ela
  /// (volta numa versão maior).
  Future<void> dismiss() async {
    final current = state;
    if (current is! UpdateBannerVisible) return;
    final version = current.info.version;
    emit(const UpdateBannerHidden());
    await _dismissed.dismiss(version);
  }

  /// Baixa o APK do Android (abre a URL no navegador → download direto). Sem
  /// artefato compatível no manifest → abre a página de download do site.
  Future<bool> download() async {
    final current = state;
    if (current is! UpdateBannerVisible) return false;
    final artifact = current.info.artifactFor(
      platform: platform,
      format: format,
      arch: arch,
    );
    return _opener.open(artifact?.url ?? fallbackUrl);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
