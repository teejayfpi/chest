import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/vault_service.dart';
import '../crypto/crypto_primitives.dart';
import '../crypto/key_derivation.dart';
import '../models/vault_models.dart';
import '../platform/app_lock_bridge.dart';
import '../platform/biometric_service.dart';
import '../platform/chest_files_bridge.dart';

/// Top-level screens the app can be showing.
enum ChestRoute { onboarding, unlock, vault, freezer, settings }

/// Why a release (unfreeze) request was allowed or refused.
enum ReleaseDecision {
  /// The user passed every required factor.
  authorized,

  /// The vault is locked, so there is no key to verify against.
  vaultLocked,

  /// The passphrase did not match.
  wrongPassphrase,

  /// Too many failures; the gate is temporarily refusing to try.
  throttled,
}

/// Outcome of an attempt to authorize a release.
class ReleaseAuthorizationResult {
  const ReleaseAuthorizationResult({
    required this.decision,
    this.retryAfter,
    this.attemptsRemaining,
  });

  /// What the gate decided.
  final ReleaseDecision decision;

  /// When [ReleaseDecision.throttled], how long until another attempt is allowed.
  final Duration? retryAfter;

  /// When [ReleaseDecision.wrongPassphrase], tries left before a lockout.
  final int? attemptsRemaining;

  /// True when the action may proceed.
  bool get authorized => decision == ReleaseDecision.authorized;
}

/// What happened when a batch of picked files was sealed and hidden.
///
/// [sealed] and [hidden] are counted separately because they can differ: a file
/// can be safely in the vault while its original is still visible in the
/// gallery, and the UI must not report that as fully hidden.
class HideSummary {
  const HideSummary({
    required this.sealed,
    required this.hidden,
    required this.stillVisible,
    required this.failures,
  });

  /// Files now sealed in the vault.
  final int sealed;

  /// Files whose original was also removed from the device.
  final int hidden;

  /// Names of files sealed but whose original could not be removed.
  final List<String> stillVisible;

  /// Per-file failures, already phrased for display.
  final List<String> failures;

  /// True when every file was both sealed and removed.
  bool get fullyHidden => sealed > 0 && stillVisible.isEmpty && failures.isEmpty;

  /// True when the batch changed nothing at all.
  bool get didNothing => sealed == 0 && failures.isEmpty;
}

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
    ChestFilesBridge? files,
  })  : vault = vaultService ?? VaultService(),
        appLock = appLock ?? AppLockBridge(),
        security = security ?? SecurityBridge(),
        biometrics = biometrics ?? BiometricService(),
        files = files ?? ChestFilesBridge();

  /// Vault storage and crypto entry point.
  final VaultService vault;

  /// Native app-freezing bridge.
  final AppLockBridge appLock;

  /// Native hardware-security probe.
  final SecurityBridge security;

  /// Biometric prompt wrapper.
  final BiometricService biometrics;

  /// Native file picker, reader and original-remover.
  final ChestFilesBridge files;

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

  /// Set once the biometric prompt has succeeded for the attempt in progress.
  ///
  /// Tracked here rather than trusted from the dialog so that "biometric *and*
  /// passphrase" is enforced by the controller, not by the widget happening to
  /// call the right methods in the right order.
  bool _biometricSatisfiedThisAttempt = false;

  /// Whether the biometric factor is currently available for release.
  bool _biometricFactorAvailable = false;

  /// One-shot token minted by [authorizeRelease] and consumed by the release
  /// call it was minted for.
  ///
  /// The UI cannot authorise a release by passing a bare `true`: it would have
  /// to know a value generated inside this controller, and each token is spent
  /// by the first release that uses it. That stops one successful confirmation
  /// from cascading into several unfreezes.
  String? _releaseAuthorizationToken;

  int _releaseFailures = 0;
  DateTime? _releaseBlockedUntil;

  bool _authorizingRelease = false;

  /// True while a release confirmation is being verified.
  ///
  /// The verification runs a full Argon2id derivation, so the UI disables its
  /// button rather than letting an impatient double-tap queue a second one.
  bool get authorizingRelease => _authorizingRelease;

  /// Failed passphrase attempts before the gate starts refusing outright.
  static const int releaseAttemptLimit = 5;

  /// True while the gate is refusing attempts.
  bool get releaseBlocked {
    final until = _releaseBlockedUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  /// How long until another release attempt is accepted, or null if allowed now.
  Duration? get releaseRetryAfter {
    final until = _releaseBlockedUntil;
    if (until == null) return null;
    final remaining = until.difference(DateTime.now());
    return remaining.isNegative ? null : remaining;
  }

  /// True when releasing an app needs a biometric prompt as well as a passphrase.
  bool get releaseNeedsBiometric =>
      _biometricsEnabled && _biometricFactorAvailable;

  /// How long the gate refuses after [failures] consecutive wrong passphrases.
  ///
  /// Grows exponentially and is capped, so a user who fat-fingers it twice is
  /// barely delayed while a scripted attempt is slowed to a crawl. The delay
  /// lives in memory only: it is defence in depth over Argon2id, which is the
  /// real cost of guessing, not a substitute for it.
  static Duration lockoutFor(int failures) {
    if (failures < 1) return Duration.zero;
    final seconds = 2 * (1 << (failures - 1).clamp(0, 8));
    return Duration(seconds: seconds.clamp(2, 900));
  }

  /// Probes whether the biometric factor can be used, for the gate UI.
  Future<void> refreshBiometricAvailability() async {
    _biometricFactorAvailable = await biometrics.canAuthenticate();
    notifyListeners();
  }

  /// Runs the biometric factor for an in-progress release confirmation.
  ///
  /// Returns true when the prompt succeeded. A device without enrolled
  /// biometrics reports false, and the passphrase factor alone still applies —
  /// the gate never becomes weaker than the passphrase.
  Future<bool> confirmReleaseWithBiometrics() async {
    final outcome = await biometrics.authenticate(
      reason: 'Confirm to release a frozen app',
      allowPasscodeFallback: false,
    );
    _biometricSatisfiedThisAttempt = outcome == BiometricOutcome.success;
    return _biometricSatisfiedThisAttempt;
  }

  /// Authorizes a release (unfreeze) with [passphrase].
  ///
  /// Two factors are required when the device can offer them: the biometric
  /// prompt must have succeeded via [confirmReleaseWithBiometrics] *and* the
  /// passphrase must match the vault. Biometrics alone deliberately never
  /// suffices — on a rooted device a fingerprint can be spoofed, and a
  /// sleeping owner's finger can be used — so the passphrase remains the factor
  /// that actually proves knowledge.
  ///
  /// On success mints a one-shot token that the matching release call consumes.
  Future<ReleaseAuthorizationResult> authorizeRelease(String passphrase) async {
    final blocked = releaseRetryAfter;
    if (blocked != null) {
      return ReleaseAuthorizationResult(
        decision: ReleaseDecision.throttled,
        retryAfter: blocked,
      );
    }

    final session = _session;
    if (session == null) {
      return const ReleaseAuthorizationResult(
        decision: ReleaseDecision.vaultLocked,
      );
    }

    _authorizingRelease = true;
    notifyListeners();

    // Consume the biometric result whatever happens next, so a failure cannot
    // leave a satisfied factor lying around for a later attempt.
    final biometricOk = _biometricSatisfiedThisAttempt;
    _biometricSatisfiedThisAttempt = false;

    try {
      if (releaseNeedsBiometric && !biometricOk) {
        return _recordReleaseFailure();
      }

      final bool ok;
      try {
        ok = await vault.verifyPassphrase(session: session, passphrase: passphrase);
      } on VaultLockedException {
        return const ReleaseAuthorizationResult(
          decision: ReleaseDecision.vaultLocked,
        );
      } on ChestCryptoException {
        return _recordReleaseFailure();
      }

      if (!ok) return _recordReleaseFailure();

      _releaseFailures = 0;
      _releaseBlockedUntil = null;
      _releaseAuthorizationToken = _newToken();
      return const ReleaseAuthorizationResult(
        decision: ReleaseDecision.authorized,
      );
    } finally {
      _authorizingRelease = false;
      notifyListeners();
    }
  }

  /// Records a failed attempt and applies the growing lockout.
  ReleaseAuthorizationResult _recordReleaseFailure() {
    _releaseFailures++;
    final attemptsRemaining = (releaseAttemptLimit - _releaseFailures).clamp(0, releaseAttemptLimit);
    if (_releaseFailures >= releaseAttemptLimit) {
      _releaseBlockedUntil = DateTime.now().add(lockoutFor(_releaseFailures));
    }
    notifyListeners();
    return ReleaseAuthorizationResult(
      decision: ReleaseDecision.wrongPassphrase,
      attemptsRemaining: attemptsRemaining,
    );
  }

  /// True when [token] matches the outstanding authorization, and spends it.
  ///
  /// Always clears the stored token, so a captured authorization cannot be
  /// replayed against a second app.
  bool _consumeAuthorization(String? token) {
    final pending = _releaseAuthorizationToken;
    _releaseAuthorizationToken = null;
    return pending != null && token != null && pending == token;
  }

  /// The token a caller must present to release a frozen app.
  ///
  /// Only meaningful immediately after [authorizeRelease] returned an authorized
  /// result; it is cleared the moment a release consumes it or a lock happens.
  String? get pendingReleaseAuthorization => _releaseAuthorizationToken;

  /// A single-use authorization token. Random rather than a counter, so its
  /// value cannot be guessed by the widget layer.
  String _newToken() => base64Url.encode(ChestRandom.bytes(18));

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
    // Any authorization minted before the lock must not survive it: otherwise a
    // dialog confirmed moments before an auto-lock would still release an app
    // afterwards, with no key in memory to have verified against.
    _releaseAuthorizationToken = null;
    _biometricSatisfiedThisAttempt = false;
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

  /// Opens the system picker and returns what the user chose.
  ///
  /// An empty list means they cancelled. The picker's grant is held so the
  /// original can be removed after sealing; [hidePickedFiles] does that, and
  /// [discardPicks] drops the grant when the user backs out.
  Future<List<PickedFile>> pickFilesToHide() async {
    if (_session == null) {
      _error = 'The vault is locked.';
      notifyListeners();
      return const [];
    }
    try {
      return await files.pickFiles();
    } on ChestFileException catch (e) {
      _error = e.message;
      notifyListeners();
      return const [];
    }
  }

  /// Drops the picker's grants for files the user chose not to seal.
  Future<void> discardPicks(List<PickedFile> picks) async {
    for (final pick in picks) {
      await files.releaseSource(pick.uri);
    }
  }

  /// Seals each picked file, then removes the original.
  ///
  /// The order is deliberate: bytes are read and sealed first, and the original
  /// is only deleted once the vault confirms it holds the sealed copy. If
  /// sealing fails, the original is left untouched, so a failure can lose
  /// nothing. If the delete fails, the entry is kept and reported as still
  /// visible rather than being rolled back, because the user's data is safer in
  /// the vault than in a half-completed state.
  Future<HideSummary> hidePickedFiles(List<PickedFile> picks) async {
    if (_session == null) {
      _error = 'The vault is locked.';
      notifyListeners();
      return const HideSummary(sealed: 0, hidden: 0, stillVisible: [], failures: []);
    }
    _setBusy(true);
    _error = null;
    var sealedCount = 0;
    var hiddenCount = 0;
    final stillVisible = <String>[];
    final failures = <String>[];

    try {
      for (final pick in picks) {
        try {
          final data = await files.readPickedFile(pick.uri);
          await vault.addFile(session: _session!, name: pick.name, data: data);
          sealedCount++;

          // Only now is it safe to destroy the original.
          final removed = await files.deleteSource(pick.uri);
          if (removed) {
            hiddenCount++;
          } else {
            stillVisible.add(pick.name);
          }
          await files.releaseSource(pick.uri);
          await refreshEntries();
        } on ChestFileException catch (e) {
          failures.add('${pick.name}: ${e.message}');
          await files.releaseSource(pick.uri);
        } catch (e) {
          failures.add('${pick.name}: ${_describe(e)}');
          await files.releaseSource(pick.uri);
        }
      }
      return HideSummary(
        sealed: sealedCount,
        hidden: hiddenCount,
        stillVisible: stillVisible,
        failures: failures,
      );
    } finally {
      _setBusy(false);
      notifyListeners();
    }
  }

  /// Writes [entry] to a cache file and opens a chooser so the user can save or
  /// send the decrypted copy.
  ///
  /// This is how a sealed photo gets back to the gallery: Chest cannot write to
  /// shared storage itself (it holds no storage permission and asks for none),
  /// so it hands the bytes to whichever app the user picks. The cache file is
  /// deleted as soon as the chooser returns, so the plaintext does not outlive
  /// the action.
  Future<bool> exportFile(VaultEntry entry) async {
    final data = await readFile(entry);
    if (data == null) return false;

    final dir = Directory('${(await getTemporaryDirectory()).path}/chest-share');
    if (!dir.existsSync()) await dir.create(recursive: true);
    final file = File('${dir.path}/${entry.id}_${_safeName(entry.displayName)}');
    await file.writeAsBytes(data, flush: true);
    try {
      return await files.shareFile(
        cachePath: file.path,
        mimeType: _mimeTypeOf(entry.originalExtension),
      );
    } finally {
      // The chooser has already handed the bytes to the target app, so the
      // plaintext copy is no longer needed.
      if (file.existsSync()) await file.delete();
    }
  }

  /// Strips path separators from a display name so it cannot escape the cache
  /// directory, which the FileProvider would refuse to publish anyway.
  static String _safeName(String name) =>
      name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// A best-effort MIME type from the stored extension, so the receiving app
  /// opens the file with the right viewer.
  static String _mimeTypeOf(String extension) {
    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'mkv':
        return 'video/x-matroska';
      case 'webm':
        return 'video/webm';
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'flac':
        return 'audio/flac';
      case 'm4a':
        return 'audio/mp4';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
        return 'text/plain';
      case 'json':
        return 'application/json';
      case 'zip':
        return 'application/zip';
      default:
        return 'application/octet-stream';
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

  /// Freezes [app], recording it only if something can actually enforce it.
  ///
  /// Freezing is not gated. It only *adds* protection, so demanding a passphrase
  /// for it would make securing a dozen apps a dozen prompts while weakening
  /// nothing. Releasing is the direction that exposes data, and that is the one
  /// [releaseApp] gates.
  ///
  /// The result is reported honestly. `applied` means a real mechanism took
  /// effect — either the platform hid the app, or the app guard will block it on
  /// open. When neither is available the app is *not* marked frozen, because a
  /// frozen flag nothing backs would tell the user an app is contained when it
  /// opens normally.
  Future<FreezeResult> freezeApp(FreezableApp app) async {
    if (app.frozen) {
      return const FreezeResult(applied: true, method: 'noop');
    }
    final result = await appLock.freeze(app.packageName, label: app.label);
    if (result.applied) {
      _apps = _apps
          .map(
            (a) => a.packageName == app.packageName
                ? a.copyWith(frozen: true, hidden: result.isHard)
                : a,
          )
          .toList(growable: false);
    }
    _capabilities = await appLock.capabilities();
    notifyListeners();
    return result;
  }

  /// Releases (unfreezes) [app], consuming the one-shot [authorization].
  ///
  /// Returns null when the authorization is missing, stale or already spent —
  /// i.e. when no successful [authorizeRelease] backs this call. A null return
  /// means the app was left frozen and no channel call was made, so an
  /// unauthorised caller cannot release anything even by driving the controller
  /// directly.
  Future<FreezeResult?> releaseApp(
    FreezableApp app, {
    required String? authorization,
  }) async {
    if (!_consumeAuthorization(authorization)) return null;
    final result = await appLock.unfreeze(app.packageName);
    _apps = _apps
        .map(
          (a) => a.packageName == app.packageName
              ? a.copyWith(frozen: false, hidden: false)
              : a,
        )
        .toList(growable: false);
    _capabilities = await appLock.capabilities();
    notifyListeners();
    return result;
  }

  /// Restores every hidden app, consuming the one-shot [authorization].
  ///
  /// Returns null when unauthorized, so the caller cannot tell an empty freeze
  /// list apart from a refused release without having been authorized first.
  Future<int?> releaseAll({required String? authorization}) async {
    if (!_consumeAuthorization(authorization)) return null;
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
