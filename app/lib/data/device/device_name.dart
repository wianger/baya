import 'dart:io';

import 'package:app/l10n/l10n.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('dev.wianger.baya/device');
String? _cached;

/// The phone's own name once [deviceName] has read it; null before.
String? get knownDeviceName => _cached;

/// What computers list this phone as: the name it has in the phone's
/// settings, or its maker and model.
Future<String> deviceName() async {
  if (_cached case final name?) return name;
  try {
    final name = await _channel.invokeMethod<String>('name');
    if (name != null && name.trim().isNotEmpty) return _cached = name.trim();
  } catch (_) {
    // No platform side (tests, desktop): fall back below.
  }
  try {
    return Platform.isAndroid ? appL10n.androidDevice : appL10n.mobile;
  } catch (_) {
    return 'Phone';
  }
}
