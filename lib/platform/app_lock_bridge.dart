import 'package:flutter/services.dart';

import '../models/vault_models.dart';

/// Dart side of the native app-freezing bridge.
///
/// Every method degrades gracefully: on a platform without the Android
/// implementation (desktop, iOS, or a unit test) the calls return empty or
/// unsupported values instead of throwing, so the UI can still render and
/// explain that freezing needs Android.
class AppLockBridge {
  AppLockBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.chest.chest/app_lock';

  final MethodChannel _channel;

  /// True when the native side has been seen to respond.
  bool _available = false;

  /// True when the native side has been seen to respond.
  bool get isAvailable => _available;

  /// Returns every launchable app with its current freeze state.
  Future<List<FreezableApp>> listApps() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('listApps');
      _available = true;
      if (raw == null) return const [];
      return raw
          .cast<Map<dynamic, dynamic>>()
          .map(FreezableApp.fromMap)
          .toList(growable: false);
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// Freezes [packageName].
  ///
  /// [label] is passed through so the native side can cache it: once a package
  /// is hidden it disappears from package queries, and the cached label is the
  /// only way to still show it in the freeze list.
  Future<FreezeResult> freeze(String packageName, {String? label}) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'freeze',
        {'packageName': packageName, 'label': label ?? packageName},
      );
      _available = true;
      if (raw == null) return const FreezeResult(applied: false, method: 'soft');
      return FreezeResult.fromMap(raw);
    } on MissingPluginException {
      return const FreezeResult(applied: false, method: 'soft');
    } on PlatformException {
      return const FreezeResult(applied: false, method: 'soft');
    }
  }

  /// Unfreezes [packageName].
  Future<FreezeResult> unfreeze(String packageName) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'unfreeze',
        {'packageName': packageName},
      );
      _available = true;
      if (raw == null) return const FreezeResult(applied: false, method: 'soft');
      return FreezeResult.fromMap(raw);
    } on MissingPluginException {
      return const FreezeResult(applied: false, method: 'soft');
    } on PlatformException {
      return const FreezeResult(applied: false, method: 'soft');
    }
  }

  /// Reports which enforcement tiers are currently active.
  Future<FreezeCapabilities> capabilities() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('capabilities');
      _available = true;
      if (raw == null) return FreezeCapabilities.unsupported;
      return FreezeCapabilities.fromMap(raw);
    } on MissingPluginException {
      return FreezeCapabilities.unsupported;
    } on PlatformException {
      return FreezeCapabilities.unsupported;
    }
  }

  /// Restores every app Chest has hidden.
  ///
  /// The escape hatch: if a freeze leaves the device in a state the user cannot
  /// undo from the list, this clears it in one call.
  Future<FreezeResult> unhideAll() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('unhideAll');
      _available = true;
      if (raw == null) return const FreezeResult(applied: false, method: 'soft');
      return FreezeResult.fromMap(raw);
    } on MissingPluginException {
      return const FreezeResult(applied: false, method: 'soft');
    } on PlatformException {
      return const FreezeResult(applied: false, method: 'soft');
    }
  }

  /// Opens the system device-admin approval dialog.
  Future<void> requestDeviceAdmin() =>
      _invokeVoid('requestDeviceAdmin');

  /// Opens the system Accessibility settings page.
  Future<void> openAccessibilitySettings() =>
      _invokeVoid('openAccessibilitySettings');

  /// Opens the system app-details page for [packageName].
  Future<void> openAppDetailsSettings(String packageName) =>
      _invokeVoid('openAppDetailsSettings', {'packageName': packageName});

  /// Enables or clears `FLAG_SECURE` on the host window.
  ///
  /// While set, Android refuses screenshots and screen recordings, and blanks
  /// the thumbnail shown in the recents switcher. The vault screen turns it on;
  /// locking turns it off again.
  Future<void> setSecureFlag(bool enabled) =>
      _invokeVoid('setSecureFlag', {'enabled': enabled});

  Future<void> _invokeVoid(String method, [Map<String, dynamic>? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
      _available = true;
    } on MissingPluginException {
      // Nothing to do: the platform has no implementation.
    } on PlatformException {
      // Surfaced through the capability flags rather than thrown at the user.
    }
  }
}

/// Dart side of the native hardware-security probe.
class SecurityBridge {
  SecurityBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.chest.chest/security';

  final MethodChannel _channel;

  /// Asks the platform where the Keystore holds its key material.
  Future<HardwareSecurity> hardwareSecurity() async {
    try {
      final raw =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('hardwareSecurity');
      if (raw == null) return HardwareSecurity.unknown;
      return HardwareSecurity.fromMap(raw);
    } on MissingPluginException {
      return HardwareSecurity.unknown;
    } on PlatformException {
      return HardwareSecurity.unknown;
    }
  }
}
