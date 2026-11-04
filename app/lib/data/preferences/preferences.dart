import 'dart:convert';

import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/domain/runs/parallel_run.dart';
import 'package:app/domain/value_objects/workspace.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:app/ui/core/themes/app_font_scale.dart';

/// App-wide UI preferences (persisted across launches).
///
/// Extends [ChangeNotifier] so widgets can `context.watch<Preferences>()`
/// and rebuild on toggle. Backed by [FlutterSecureStorage] (same store
/// already used by pairing). Call [load] once during bootstrap before
/// the first frame to hydrate the in-memory cache.
class Preferences extends ChangeNotifier {
  final FlutterSecureStorage _store;
  bool _hideToolCalls = false;
  Map<String, String> _sessionNames = {};
  Map<String, String> _sessionWorkspaces = {};
  Map<String, String> _workspaceNames = {};
  String? _selectedWorkspace;
  String? _selectedDeviceEpk;
  Map<String, String> _workspacesByDevice = {};
  Future<void> _navigationWrites = Future.value();
  String? _tailnetDomain;
  bool _onboardingCompleted = false;
  ThemeMode _themeMode = ThemeMode.system;
  AppFontScale _fontScale = AppFontScale.standard;

  Preferences([FlutterSecureStorage? store])
    : _store = store ?? const FlutterSecureStorage();

  static const _kSessionNamesKey = 'prefs.session_names';
  static const _kSessionWorkspacesKey = 'prefs.session_workspaces';
  static const _kWorkspaceNamesKey = 'prefs.workspace_names';
  static const _kNavigationKey = 'prefs.workspace_navigation';

  static const _kHideToolCallsKey = 'prefs.hide_tool_calls';
  static const _kTailnetDomainKey = 'prefs.tailnet_domain';
  static const _kOnboardingCompletedKey = 'prefs.onboarding_completed';
  static const _kThemeModeKey = 'prefs.theme_mode';
  static const _kFontScaleKey = 'prefs.font_scale';
  static const _kLanguageKey = 'prefs.language';
  static const _kRunsKey = 'prefs.parallel_runs';

  /// True → chat hides `ToolEvent` rows (only user/assistant text remain).
  bool get hideToolCalls => _hideToolCalls;

  /// The owner's Tailscale domain (e.g. `tail1234.ts.net`), learned from the
  /// last pairing; completes the short computer names typed when pairing.
  String? get tailnetDomain => _tailnetDomain;

  /// `true` after the user completed the 3-step onboarding flow at least
  /// once. Drives `/boot` redirect: false → `/onboarding`, true → `/home`.
  bool get onboardingCompleted => _onboardingCompleted;

  /// Preferred app theme. `ThemeMode.system` (default) follows the OS
  /// light/dark setting; `light` / `dark` pin it. Consumed by `MaterialApp`
  /// in `main.dart` and set from the Settings "Display" section.
  ThemeMode get themeMode => _themeMode;

  /// App language code (`en`, `zh`); null follows the device.
  String? get language => _language;
  String? _language;

  /// Preferred text size. Applied as a `TextScaler` above the
  /// router in `main.dart`, so it scales the whole UI — including the per-widget
  /// `copyWith(fontSize: …)` overrides that a typography-only change would miss.
  AppFontScale get fontScale => _fontScale;

  /// Hydrate from secure storage. Safe to call multiple times.
  Future<void> load() async {
    var changed = false;

    final raw = await _store.read(key: _kHideToolCallsKey);
    final next = raw == 'true';
    if (next != _hideToolCalls) {
      _hideToolCalls = next;
      changed = true;
    }

    final tailnet = await _store.read(key: _kTailnetDomainKey);
    if (tailnet != _tailnetDomain) {
      _tailnetDomain = tailnet;
      changed = true;
    }

    final onboarded = await _store.read(key: _kOnboardingCompletedKey);
    final onboardedBool = onboarded == 'true';
    if (onboardedBool != _onboardingCompleted) {
      _onboardingCompleted = onboardedBool;
      changed = true;
    }

    final theme = await _store.read(key: _kThemeModeKey);
    final themeMode = _themeModeFromString(theme);
    if (themeMode != _themeMode) {
      _themeMode = themeMode;
      changed = true;
    }

    final language = await _store.read(key: _kLanguageKey);
    if (language != _language) {
      _language = language;
      changed = true;
    }

    final scale = AppFontScale.fromName(await _store.read(key: _kFontScaleKey));
    if (scale != _fontScale) {
      _fontScale = scale;
      changed = true;
    }

    String? device;
    final remembered = <String, String>{};
    final navigationRaw = await _store.read(key: _kNavigationKey);
    try {
      final navigation = navigationRaw == null
          ? null
          : jsonDecode(navigationRaw);
      if (navigation is Map) {
        device = navigation['device'] is String
            ? toStandardB64(navigation['device'] as String)
            : null;
        remembered.clear();
        final entries = navigation['workspaces'];
        if (entries is Map) {
          for (final entry in entries.entries) {
            if (entry.key is! String || entry.value is! String) continue;
            final epk = toStandardB64(entry.key as String);
            final key = entry.value as String;
            if (isWorkspaceKeyForDevice(key, epk)) remembered[epk] = key;
          }
        }
      }
    } on FormatException {
      // A damaged navigation preference falls back to Inbox.
    }
    if (device != _selectedDeviceEpk ||
        !mapEquals(remembered, _workspacesByDevice)) {
      _selectedDeviceEpk = device;
      _workspacesByDevice = remembered;
      changed = true;
    }
    _selectedWorkspace = remembered[device];
    final namesRaw = await _store.read(key: _kSessionNamesKey);
    Map<String, String> names = {};
    try {
      final decoded = namesRaw == null ? null : jsonDecode(namesRaw);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          if (entry.key is String &&
              entry.value is String &&
              (entry.value as String).trim().isNotEmpty) {
            names[entry.key as String] = (entry.value as String).trim();
          }
        }
      }
    } on FormatException {
      /* Invalid preference, fall back to the session title. */
    }
    if (!mapEquals(names, _sessionNames)) {
      _sessionNames = names;
      changed = true;
    }
    final sessionWorkspacesRaw = await _store.read(key: _kSessionWorkspacesKey);
    Map<String, String> sessionWorkspaces = {};
    try {
      final decoded = sessionWorkspacesRaw == null
          ? null
          : jsonDecode(sessionWorkspacesRaw);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          if (entry.key is String &&
              entry.value is String &&
              (entry.value as String).trim().isNotEmpty) {
            final conversationDevice = toStandardB64(
              (entry.key as String).split(':').first,
            );
            final workspace = (entry.value as String).trim();
            if (isWorkspaceKeyForDevice(workspace, conversationDevice)) {
              sessionWorkspaces[entry.key as String] = workspace;
            }
          }
        }
      }
    } on FormatException {
      /* Invalid preference, fall back to Inbox. */
    }
    if (!mapEquals(sessionWorkspaces, _sessionWorkspaces)) {
      _sessionWorkspaces = sessionWorkspaces;
      changed = true;
    }
    final workspaceNamesRaw = await _store.read(key: _kWorkspaceNamesKey);
    Map<String, String> workspaceNames = {};
    try {
      final decoded = workspaceNamesRaw == null
          ? null
          : jsonDecode(workspaceNamesRaw);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          if (entry.key is String &&
              entry.value is String &&
              (entry.value as String).trim().isNotEmpty &&
              isWorkspaceKey(entry.key as String)) {
            workspaceNames[entry.key as String] = (entry.value as String)
                .trim();
          }
        }
      }
    } on FormatException {
      /* Invalid preference. */
    }
    if (!mapEquals(workspaceNames, _workspaceNames)) {
      _workspaceNames = workspaceNames;
      changed = true;
    }
    final runsRaw = await _store.read(key: _kRunsKey);
    try {
      final decoded = runsRaw == null ? null : jsonDecode(runsRaw);
      if (decoded is List) {
        _runs = [
          for (final run in decoded)
            if (run is Map) ParallelRun.fromJson(run.cast<String, dynamic>()),
        ];
        changed = true;
      }
    } on Object {
      /* Invalid preference. */
    }
    if (changed) notifyListeners();
  }

  /// Parallel runs started from this phone, newest first.
  List<ParallelRun> get runs => List.unmodifiable(_runs);
  List<ParallelRun> _runs = const [];
  static const _runsKept = 20;

  ParallelRun? run(String id) => _runs.where((run) => run.id == id).firstOrNull;

  Future<void> addRun(ParallelRun run) =>
      _writeRuns([run, ..._runs.where((r) => r.id != run.id)]);

  Future<void> removeRun(String id) =>
      _writeRuns(_runs.where((run) => run.id != id).toList());

  Future<void> _writeRuns(List<ParallelRun> runs) async {
    final kept = runs.take(_runsKept).toList(growable: false);
    await _store.write(
      key: _kRunsKey,
      value: jsonEncode([for (final run in kept) run.toJson()]),
    );
    _runs = kept;
    notifyListeners();
  }

  static String _conversationKey(String epk, String sessionId) =>
      '${toStandardB64(epk)}:$sessionId';

  String? get selectedWorkspace => _selectedWorkspace;
  String? get selectedDeviceEpk => _selectedDeviceEpk;
  String? workspaceForDevice(String epk) {
    final device = toStandardB64(epk);
    final workspace = _workspacesByDevice[device];
    return workspace != null && isWorkspaceKeyForDevice(workspace, device)
        ? workspace
        : null;
  }

  /// Local display-name override for a conversation. Null → use the name the
  /// computer announced. Kept on this phone so renaming never touches the
  /// running agent or another device.
  String? sessionName(String epk, String sessionId) =>
      _sessionNames[_conversationKey(epk, sessionId)];

  Future<void> setSessionName(
    String epk,
    String sessionId,
    String? name,
  ) async {
    final key = _conversationKey(epk, sessionId);
    final trimmed = name?.trim();
    final next = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    final before = _sessionNames[key];
    if (next == before) return;
    if (next == null) {
      _sessionNames.remove(key);
    } else {
      _sessionNames[key] = next;
    }
    try {
      await _store.write(
        key: _kSessionNamesKey,
        value: jsonEncode(_sessionNames),
      );
    } catch (_) {
      if (before == null) {
        _sessionNames.remove(key);
      } else {
        _sessionNames[key] = before;
      }
      rethrow;
    }
    notifyListeners();
  }

  /// Display name for a logical workspace. Inbox has no stored name until the
  /// user renames it.
  String? workspaceName(String key) =>
      isWorkspaceKey(key) ? _workspaceNames[key] : null;

  bool isCustomWorkspace(String key) =>
      isWorkspaceKey(key) &&
      !isInboxWorkspace(key) &&
      _workspaceNames.containsKey(key);

  Iterable<String> customWorkspaceKeysForDevice(String epk) {
    final device = toStandardB64(epk);
    return _workspaceNames.keys.where(
      (key) => isWorkspaceKeyForDevice(key, device),
    );
  }

  String? workspaceForSession(String epk, String sessionId) {
    final device = toStandardB64(epk);
    final workspace = _sessionWorkspaces[_conversationKey(device, sessionId)];
    return workspace != null && isWorkspaceKeyForDevice(workspace, device)
        ? workspace
        : null;
  }

  Future<void> setSessionWorkspace(
    String epk,
    String sessionId,
    String? workspaceKey,
  ) async {
    final key = _conversationKey(epk, sessionId);
    final next = workspaceKey?.trim();
    final device = toStandardB64(epk);
    if (next != null &&
        next.isNotEmpty &&
        !isWorkspaceKeyForDevice(next, device)) {
      throw ArgumentError.value(
        workspaceKey,
        'workspaceKey',
        'Workspace must use a logical key for the same device',
      );
    }
    final before = _sessionWorkspaces[key];
    if ((next == null || next.isEmpty) && before == null) return;
    if (next == before) return;
    if (next == null || next.isEmpty) {
      _sessionWorkspaces.remove(key);
    } else {
      _sessionWorkspaces[key] = next;
    }
    try {
      await _store.write(
        key: _kSessionWorkspacesKey,
        value: jsonEncode(_sessionWorkspaces),
      );
    } catch (_) {
      if (before == null) {
        _sessionWorkspaces.remove(key);
      } else {
        _sessionWorkspaces[key] = before;
      }
      rethrow;
    }
    notifyListeners();
  }

  Future<void> setWorkspaceName(String key, String name) async {
    if (!isWorkspaceKey(key)) {
      throw ArgumentError.value(key, 'key', 'Invalid logical workspace key');
    }
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final before = _workspaceNames[key];
    if (before == trimmed) return;
    _workspaceNames[key] = trimmed;
    try {
      await _store.write(
        key: _kWorkspaceNamesKey,
        value: jsonEncode(_workspaceNames),
      );
    } catch (_) {
      if (before == null) {
        _workspaceNames.remove(key);
      } else {
        _workspaceNames[key] = before;
      }
      rethrow;
    }
    notifyListeners();
  }

  bool canDeleteWorkspace(String key) =>
      isWorkspaceKey(key) && !isInboxWorkspace(key);

  /// Delete a logical workspace without deleting its sessions or computer
  /// history. Its sessions fall back to the device Inbox.
  Future<void> deleteWorkspace(String key) async {
    if (!canDeleteWorkspace(key)) {
      throw ArgumentError.value(
        key,
        'key',
        'The device Inbox cannot be deleted',
      );
    }
    final device = workspaceDevice(key);
    final beforeNames = Map<String, String>.of(_workspaceNames);
    final beforeSessionWorkspaces = Map<String, String>.of(_sessionWorkspaces);
    final beforeByDevice = Map<String, String>.of(_workspacesByDevice);
    final beforeSelectedDevice = _selectedDeviceEpk;
    final beforeSelectedWorkspace = _selectedWorkspace;

    _workspaceNames.remove(key);
    _sessionWorkspaces.removeWhere((_, workspace) => workspace == key);
    final remembered = Map<String, String>.of(_workspacesByDevice);
    if (device != null) {
      remembered.removeWhere(
        (selectedDevice, workspace) =>
            selectedDevice == device && workspace == key,
      );
    }
    _workspacesByDevice = remembered;
    if (_selectedDeviceEpk == device) {
      _selectedWorkspace = remembered[device];
    }

    try {
      await _store.write(
        key: _kWorkspaceNamesKey,
        value: jsonEncode(_workspaceNames),
      );
      await _store.write(
        key: _kSessionWorkspacesKey,
        value: jsonEncode(_sessionWorkspaces),
      );
      if (remembered.length != beforeByDevice.length ||
          !mapEquals(remembered, beforeByDevice)) {
        await _store.write(
          key: _kNavigationKey,
          value: jsonEncode({
            'device': _selectedDeviceEpk,
            'workspaces': remembered,
          }),
        );
      }
    } catch (_) {
      _workspaceNames
        ..clear()
        ..addAll(beforeNames);
      _sessionWorkspaces
        ..clear()
        ..addAll(beforeSessionWorkspaces);
      _workspacesByDevice
        ..clear()
        ..addAll(beforeByDevice);
      _selectedDeviceEpk = beforeSelectedDevice;
      _selectedWorkspace = beforeSelectedWorkspace;
      rethrow;
    }
    notifyListeners();
  }

  Future<void> setSelectedDevice(String? epk) =>
      _updateNavigation(epk == null ? null : toStandardB64(epk));

  Future<void> setSelectedWorkspace(String value) {
    final device = workspaceDevice(value);
    if (device == null) {
      throw ArgumentError.value(value, 'value', 'Invalid workspace');
    }
    final epk = toStandardB64(device);
    final normalized = workspaceKey(epk, workspaceId(value)!);
    return _updateNavigation(epk, workspace: normalized);
  }

  Future<void> _updateNavigation(String? epk, {String? workspace}) {
    final pending = _navigationWrites.then((_) async {
      final remembered = Map<String, String>.of(_workspacesByDevice);
      if (epk != null &&
          workspace != null &&
          isWorkspaceKeyForDevice(workspace, epk)) {
        remembered[epk] = workspace;
      }
      if (_selectedDeviceEpk == epk &&
          mapEquals(remembered, _workspacesByDevice)) {
        return;
      }
      // One write commits device and per-device workspaces together. Publish
      // only after persistence succeeds, and serialize rapid selector changes.
      await _store.write(
        key: _kNavigationKey,
        value: jsonEncode({'device': epk, 'workspaces': remembered}),
      );
      _selectedDeviceEpk = epk;
      _workspacesByDevice = remembered;
      _selectedWorkspace = epk == null ? null : remembered[epk];
      notifyListeners();
    });
    _navigationWrites = pending.catchError((Object _) {});
    return pending;
  }

  Future<void> setHideToolCalls(bool value) async {
    if (_hideToolCalls == value) return;
    _hideToolCalls = value;
    await _store.write(key: _kHideToolCallsKey, value: value.toString());
    notifyListeners();
  }

  Future<void> setTailnetDomain(String value) async {
    if (value == _tailnetDomain) return;
    _tailnetDomain = value;
    await _store.write(key: _kTailnetDomainKey, value: value);
    notifyListeners();
  }

  Future<void> setOnboardingCompleted(bool value) async {
    if (_onboardingCompleted == value) return;
    _onboardingCompleted = value;
    await _store.write(key: _kOnboardingCompletedKey, value: value.toString());
    notifyListeners();
  }

  /// Persist the preferred [ThemeMode]. Stored as a stable string key so the
  /// value survives enum reordering.
  Future<void> setThemeMode(ThemeMode value) async {
    if (_themeMode == value) return;
    _themeMode = value;
    await _store.write(key: _kThemeModeKey, value: value.name);
    notifyListeners();
  }

  /// Persist the app language; null follows the device.
  Future<void> setLanguage(String? value) async {
    if (_language == value) return;
    _language = value;
    if (value == null) {
      await _store.delete(key: _kLanguageKey);
    } else {
      await _store.write(key: _kLanguageKey, value: value);
    }
    notifyListeners();
  }

  /// Persist the preferred [AppFontScale]. Stored by `name` so the value
  /// survives enum reordering.
  Future<void> setFontScale(AppFontScale value) async {
    if (_fontScale == value) return;
    _fontScale = value;
    await _store.write(key: _kFontScaleKey, value: value.name);
    notifyListeners();
  }

  static ThemeMode _themeModeFromString(String? raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}
