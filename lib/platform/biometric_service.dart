import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// Outcome of a biometric prompt.
enum BiometricOutcome {
  /// The user authenticated successfully.
  success,

  /// The user cancelled or failed the prompt.
  failed,

  /// The device has no enrolled biometrics.
  unavailable,

  /// The platform refused for a reason the user cannot act on here.
  error,
}

/// Wraps `local_auth`.
///
/// Biometrics are used only as a *convenience gate* over the vault, never as key
/// material. The vault key comes from the passphrase through Argon2id; a
/// fingerprint simply avoids retyping it. That distinction matters because
/// biometric APIs on Android can be spoofed on rooted devices, so treating them
/// as the sole protection would weaken the vault rather than strengthen it.
class BiometricService {
  BiometricService({LocalAuthentication? auth})
      : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  /// True when the device can perform biometric authentication.
  Future<bool> isSupported() async {
    try {
      return await _auth.isDeviceSupported();
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// True when biometrics are supported and at least one is enrolled.
  Future<bool> canAuthenticate() async {
    try {
      return await _auth.canCheckBiometrics && await _auth.isDeviceSupported();
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// The biometric types the device can offer.
  Future<List<BiometricType>> availableTypes() async {
    try {
      return await _auth.getAvailableBiometrics();
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// Prompts for biometric authentication.
  ///
  /// [reason] is shown by the OS. Returns [BiometricOutcome.unavailable] rather
  /// than throwing when nothing is enrolled, so the caller can fall back to the
  /// passphrase without special-casing exceptions.
  Future<BiometricOutcome> authenticate({
    required String reason,
    bool allowPasscodeFallback = true,
  }) async {
    try {
      if (!await canAuthenticate()) return BiometricOutcome.unavailable;
      final ok = await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: !allowPasscodeFallback,
        persistAcrossBackgrounding: true,
      );
      return ok ? BiometricOutcome.success : BiometricOutcome.failed;
    } on MissingPluginException {
      return BiometricOutcome.unavailable;
    } on LocalAuthException catch (e) {
      // noBiometricHardware / noBiometricsEnrolled / deviceCredentialsNotSet
      // all mean "cannot prompt on this device right now".
      switch (e.code) {
        case LocalAuthExceptionCode.noBiometricHardware:
        case LocalAuthExceptionCode.noBiometricsEnrolled:
        case LocalAuthExceptionCode.noCredentialsSet:
          return BiometricOutcome.unavailable;
        default:
          return BiometricOutcome.error;
      }
    } on PlatformException {
      return BiometricOutcome.error;
    }
  }
}
