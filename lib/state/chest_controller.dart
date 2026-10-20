import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/vault_service.dart';
import '../crypto/crypto_primitives.dart';
import '../crypto/key_derivation.dart';
import '../models/vault_models.dart';
import '../platform/app_lock_bridge.dart';
import '../platform/biometric_service.dart';

/// Top-level screens the app can be showing.
enum ChestRoute { onboarding, unlock, vault, freezer, settings }

/// Single source of truth for the UI.
///
/// Holds the unlocked [VaultSession] and mediates every call into the crypto
/// and platform layers so widgets never touch keys or channels directly. It also
/// owns the auto-lock timer, because a vault that stays unlocked indefinitely is
/// the most likely way for its contents to leak.
class ChestController extends ChangeNotifier {
  ChestController({
    VaultService? vaultService,
    AppLockBridge? appLock,
    SecurityBridge? security,
    BiometricService? biometrics,
  })  : vault = vaultService ?? VaultService(),
        appLock = appLock ?? AppLockBridge(),
        security = security ?? SecurityBridge(),
        biometrics = biometrics ?? BiometricService();

  /// Vault storage and crypto entry point.
  final VaultService vault;

  /// Native app-freezing bridge.
  final AppLockBridge appLock;

  /// Native hardware-security probe.
  final SecurityBridge security;

  /// Biometric prompt wrapper.
  final BiometricService biometrics;

  ChestRoute _route = ChestRoute.onboarding;
  ChestRoute get route => _route;

  VaultSession? _session;
  bool get isUnlocked => _session != null;

  KdfProfile _profile = KdfProfile.hardened;
  KdfProfile get profile => _profile;

  bool _busy = false;
  bool get busy => _busy;

  String? _error;
  String? get error => _error;

  List<VaultEntry> _entries = const [];
  List<VaultEntry> get entries => List.unmodifiable(_entries);

  List<FreezableApp> _apps = const [];
  List<FreezableApp> get apps => List.unmodifiable(_apps);

  FreezeCapabilities _capabilities = FreezeCapabilities.unsupported;
  FreezeCapabilities get capabilities => _capabilities;

  HardwareSecurity _hardware = HardwareSecurity.unknown;
  HardwareSecurity get hardware => _hardware;

  bool _biometricsEnabled = true;
  bool get biometricsEnabled => _biometricsEnabled;

  /// How long the vault stays unlocked with no interaction.
  Duration autoLockAfter = const Duration(minutes: 3);

  Timer? _autoLockTimer;

  /// Resolves the initial route by checking whether a vault exists.
  Future<void> initialise() async {
    _setBusy(true);
    try {
      _route = await vault.exists() ? ChestRoute.unlock : ChestRoute.onboarding;
      _capabilities = await appLock.capabilities();
      _hardware = await security.hardwareSecurity();
    } catch (e) {
      _error = 'Could not read vault state: $e';
      _route = ChestRoute.onboarding;
    } finally {
      _setBusy(false);
    }
  }

  /// Creates the vault and unlocks it.
  Future<bool> createVault(String passphrase) async {
    _setBusy(true);
    _error = null;
    try {
      _session = await vault.create(passphrase: passphrase, profile: _profile);
      _entries = const [];
      _route = ChestRoute.vault;
      _armAutoLock();
      await _applyScreenshotProtection(true);
      return true;
    } catch (e) {
      _error = _describe(e);
      return false;
    } finally {
      _setBusy(false);
    }
  }

  /// Unlocks the vault with [passphrase].
  Future<bool> unlock(String passphrase) async {
    _setBusy(true);
    _error = null;
    try {
      _session = await vault.unlock(passphrase: passphrase);
      _entries = await vault.listEntries(_session!);
      _route = ChestRoute.vault;
      _armAutoLock();
      await _applyScreenshotProtection(true);
      return true;
    } catch (e) {
      _error = _describe(e);
      return false;
    } finally {
      _setBusy(false);
    }
  }

  /// Unlocks using a biometric prompt when the device supports it.
  ///
  /// Note that this only replaces the *passphrase entry*, not the key
  /// derivation: the caller must still supply the passphrase once the prompt
  /// succeeds, because the vault key is derived from it and is never stored.
  Future<BiometricOutcome> requestBiometricUnlock() => biometrics.authenticate(
        reason: 'Unlock Chest',
      );

  /// Locks the vault and zeroes its key material.
  void lock() {
    _cancelAutoLock();
    _session?.dispose();
    _session = null;
    _entries = const [];
    _apps = const [];
    _route = ChestRoute.unlock;
    _error = null;
    unawaited(_applyScreenshotProtection(false));
    notifyListeners();
  }

  /// Toggles the platform screenshot block.
  ///
  /// Best effort: on a platform without the native bridge this is a no-op, and
  /// the vault is still protected by the encryption itself.
  Future<void> _applyScreenshotProtection(bool enabled) =>
      appLock.setSecureFlag(enabled);

  /// Records user interaction, deferring the auto-lock deadline.
  void noteActivity() {
    if (_session == null) return;
    _armAutoLock();
  }

  /// Loads vault entries.
  Future<void> refreshEntries() async {
    final session = _session;
    if (session == null) return;
    _entries = await vault.listEntries(session);
    notifyListeners();
  }

  /// Searches entries by name.
  Future<void> search(String query) async {
    final session = _session;
    if (session == null) return;
    _entries = await vault.search(session: session, query: query);
    notifyListeners();
  }

  /// Encrypts [data] into the vault under [name].
  Future<VaultEntry?> addFile({required String name, required Uint8List data}) async {
    final session = _session;
    if (session == null) {
      _error = 'The vault is locked.';
      notifyListeners();
      return null;
    }
    _setBusy(true);
    _error = null;
    try {
      final entry = await vault.addFile(session: session, name: name, data: data);
      await refreshEntries();
      return entry;
    } catch (e) {
      _error = _describe(e);
      return null;
    } finally {
      _setBusy(false);
    }
  }

  /// Decrypts [entry].
  Future<Uint8List?> readFile(VaultEntry entry) async {
    final session = _session;
    if (session == null) return null;
    try {
      return await vault.readFile(session: session, entry: entry);
    } catch (e) {
      _error = _describe(e);
      notifyListeners();
      return null;
    }
  }

  /// Deletes [entry].
  Future<void> deleteFile(VaultEntry entry) async {
    final session = _session;
    if (session == null) return;
    await vault.deleteFile(session: session, entry: entry);
    await refreshEntries();
  }

  /// Loads the device's launchable apps.
  Future<void> loadApps() async {
    _setBusy(true);
    try {
      _capabilities = await appLock.capabilities();
      _apps = await appLock.listApps();
    } finally {
      _setBusy(false);
    }
  }

  /// Freezes or unfreezes [app], updating the list in place.
  ///
  /// The result is reported honestly: when the platform refused the hide (no
  /// device-owner provisioning), the app is *not* marked frozen, because a
  /// frozen flag the platform does not back would tell the user an app is hidden
  /// from the launcher when it is not.
  Future<FreezeResult> toggleFreeze(FreezableApp app) async {
    final result = app.frozen
        ? await appLock.unfreeze(app.packageName)
        : await appLock.freeze(app.packageName, label: app.label);
    _apps = _apps
        .map(
          (a) => a.packageName == app.packageName
              ? a.copyWith(frozen: result.applied, hidden: result.isHard)
              : a,
        )
        .toList(growable: false);
    _capabilities = await appLock.capabilities();
    notifyListeners();
    return result;
  }

  /// Restores every hidden app and clears the freeze list.
  ///
  /// Returns the number of apps the platform actually restored.
  Future<int> unhideAll() async {
    _setBusy(true);
    try {
      final result = await appLock.unhideAll();
      _apps = await appLock.listApps();
      _capabilities = await appLock.capabilities();
      return result.restored;
    } finally {
      _setBusy(false);
    }
  }

  /// Refreshes the native capability flags, for use when returning from
  /// Settings.
  Future<void> refreshCapabilities() async {
    _capabilities = await appLock.capabilities();
    _hardware = await security.hardwareSecurity();
    notifyListeners();
  }

  /// Toggles the biometric convenience gate.
  void setBiometricsEnabled(bool value) {
    _biometricsEnabled = value;
    notifyListeners();
  }

  /// Selects the Argon2id preset used for new vaults.
  void setProfile(KdfProfile value) {
    _profile = value;
    notifyListeners();
  }

  /// Navigates to [route].
  void goTo(ChestRoute route) {
    _route = route;
    _error = null;
    notifyListeners();
  }

  /// Clears the current error banner.
  void clearError() {
    _error = null;
    notifyListeners();
  }

  void _armAutoLock() {
    _cancelAutoLock();
    _autoLockTimer = Timer(autoLockAfter, lock);
  }

  void _cancelAutoLock() {
    _autoLockTimer?.cancel();
    _autoLockTimer = null;
  }

  void _setBusy(bool value) {
    _busy = value;
    notifyListeners();
  }

  /// Turns exceptions into something a user can act on.
  ///
  /// Branches on the exception *type* rather than on its text: the crypto
  /// exceptions all stringify to their base class name, so a message match
  /// would fall through to the raw, unhelpful text.
  String _describe(Object e) {
    if (e is ChestAuthenticationException) {
      return 'That passphrase did not open the vault.';
    }
    if (e is ChestCryptoException) {
      switch (e.code) {
        case 'empty_passphrase':
          return 'Enter your passphrase.';
        case 'vault_already_exists':
          return 'A vault already exists on this device.';
        case 'vault_missing':
          return 'No vault was found on this device.';
        case 'vault_locked':
          return 'The vault is locked.';
        case 'malformed_container':
          return 'The vault file is damaged or was not written by Chest.';
      }
    }
    return 'Something went wrong: $e';
  }

  @override
  void dispose() {
    _cancelAutoLock();
    _session?.dispose();
    _session = null;
    super.dispose();
  }
}
