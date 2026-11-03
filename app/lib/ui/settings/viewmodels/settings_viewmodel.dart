import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/hosts/hosts.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/settings/states/settings_state.dart';

/// Paired computers: rename and forget. [Hosts] follows the storage, so a
/// forgotten computer's connection closes by itself.
class SettingsViewModel extends ViewModel<SettingsState> {
  final PairingStorage _storage;
  final Preferences _prefs;
  final Hosts _hosts;
  bool _disposed = false;

  SettingsViewModel(this._storage, this._prefs, this._hosts)
    : super(const SettingsLoading()) {
    _load();
  }

  /// Whether the computer at [epk] is connected right now.
  bool isOnline(String epk) => _hosts.byKey(epk)?.isOnline ?? false;

  Future<void> _load() async {
    final peers = await _storage.listPeers();
    if (_disposed) return;
    if (peers.isEmpty) {
      emit(const SettingsNoPeer());
      return;
    }
    emit(SettingsList(peers: peers));
  }

  /// Set or clear the local nickname for the peer at [epk].
  Future<void> setNickname(String epk, String? nickname) async {
    final s = state;
    if (s is! SettingsList) return;
    PeerRecord? target;
    for (final p in s.peers) {
      if (p.remoteEpk == epk) {
        target = p;
        break;
      }
    }
    if (target == null) return;
    final trimmed = nickname?.trim();
    final normalized = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    final updated = target.copyWith(nickname: normalized);
    await _storage.savePeer(updated);
    await _load();
  }

  /// Forget the computer on this phone. If it was the last one, the next
  /// boot starts with onboarding again.
  Future<void> revoke(String epk) async {
    await _storage.deleteSessions(epk);
    await _storage.deletePeer(epk);
    if ((await _storage.listPeers()).isEmpty) {
      await _prefs.setOnboardingCompleted(false);
    }
    await _load();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
