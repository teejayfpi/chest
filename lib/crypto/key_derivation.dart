import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'crypto_primitives.dart';

/// Strength presets for the Argon2id password-hashing layer.
///
/// This is the *first* encryption layer: everything downstream is only as
/// strong as the cost of guessing the passphrase, so the presets sit
/// comfortably above the OWASP minimum rather than being tuned for speed.
enum KdfProfile {
  /// 64 MiB / 3 passes. Acceptable on mid-range hardware.
  standard(
    id: 1,
    memoryKib: 64 * 1024,
    iterations: 3,
    parallelism: 2,
    label: 'Standard',
    description: '64 MiB memory, 3 passes. Unlocks quickly on most phones.',
  ),

  /// 128 MiB / 4 passes. The default for new vaults.
  hardened(
    id: 2,
    memoryKib: 128 * 1024,
    iterations: 4,
    parallelism: 4,
    label: 'Hardened',
    description: '128 MiB memory, 4 passes. The recommended balance.',
  ),

  /// 256 MiB / 6 passes. Slow by design; for high-value containers.
  paranoid(
    id: 3,
    memoryKib: 256 * 1024,
    iterations: 6,
    parallelism: 4,
    label: 'Paranoid',
    description: '256 MiB memory, 6 passes. Slower to unlock, costlier to attack.',
  );

  const KdfProfile({
    required this.id,
    required this.memoryKib,
    required this.iterations,
    required this.parallelism,
    required this.label,
    required this.description,
  });

  /// Stable identifier persisted inside the container header.
  final int id;

  /// Argon2id memory cost in kibibytes.
  final int memoryKib;

  /// Argon2id time cost (number of passes).
  final int iterations;

  /// Argon2id lane count.
  final int parallelism;

  /// Display name for the preset.
  final String label;

  /// One-line explanation of the cost, shown when choosing a preset.
  final String description;

  /// Salt length in bytes. 128 bits is the RFC 9106 recommendation.
  static const int saltLength = 16;

  /// Resolves a profile from its persisted [id].
  static KdfProfile fromId(int id) {
    for (final profile in KdfProfile.values) {
      if (profile.id == id) return profile;
    }
    throw ChestFormatException('unknown kdf profile id $id');
  }
}

/// The separated subkeys produced by [KeyDerivation.deriveCascadeKeys].
class CascadeKeys {
  CascadeKeys({
    required this.aesKey,
    required this.chachaKey,
    required this.hmacKey,
    required this.headerMacKey,
  });

  /// Key for the AES-256-GCM (innermost) layer.
  final Uint8List aesKey;

  /// Key for the XChaCha20-Poly1305 (outer) layer.
  final Uint8List chachaKey;

  /// Key for the outer HMAC-SHA256 integrity envelope.
  final Uint8List hmacKey;

  /// Key that authenticates container headers.
  final Uint8List headerMacKey;

  /// Zeroes every subkey.
  void wipe() {
    wipeAllKeys([aesKey, chachaKey, hmacKey, headerMacKey]);
  }
}

/// Zeroes a list of byte buffers.
void wipeAllKeys(Iterable<Uint8List> buffers) {
  for (final buffer in buffers) {
    wipe(buffer);
  }
}

/// Derives and separates keys for the Chest cascade.
///
/// Intentionally stateless and pure so the whole derivation chain can be
/// unit-tested without touching a platform channel.
class KeyDerivation {
  KeyDerivation._();

  /// Root-key output length in bytes (256-bit).
  static const int rootKeyLength = 32;

  // Domain-separation labels. Changing any of these breaks existing
  // containers, so they are versioned alongside the container format.
  static const String _labelAes = 'chest.v1.kek.aes256gcm';
  static const String _labelChacha = 'chest.v1.kek.xchacha20poly1305';
  static const String _labelHmac = 'chest.v1.mac.hmacsha256';
  static const String _labelStream = 'chest.v1.stream';
  static const String _labelNameKey = 'chest.v1.name.hmacsha256';
  static const String _labelHeaderMac = 'chest.v1.header.hmacsha256';

  /// Layer 1 — turns a passphrase into a 256-bit root key using Argon2id.
  ///
  /// [salt] must be exactly [KdfProfile.saltLength] bytes and unique per vault.
  static Future<Uint8List> deriveRootKey({
    required String passphrase,
    required Uint8List salt,
    required KdfProfile profile,
  }) async {
    if (salt.length != KdfProfile.saltLength) {
      throw ArgumentError.value(
        salt.length,
        'salt',
        'must be ${KdfProfile.saltLength} bytes',
      );
    }
    if (passphrase.isEmpty) {
      throw const ChestCryptoException('empty_passphrase');
    }

    final argon2 = Argon2id(
      memory: profile.memoryKib,
      iterations: profile.iterations,
      parallelism: profile.parallelism,
      hashLength: rootKeyLength,
    );

    final key = await argon2.deriveKey(
      secretKey: SecretKey(passphrase.codeUnits),
      nonce: salt,
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  /// Layer 2 — HKDF-SHA256 key separation.
  ///
  /// A root key is never used directly for two purposes. Each purpose gets an
  /// independent 256-bit subkey bound to [label] and [salt], so a weakness in
  /// one layer cannot be replayed against another.
  static Future<Uint8List> expand({
    required Uint8List rootKey,
    required String label,
    required Uint8List salt,
    int length = 32,
  }) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: length);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(rootKey),
      nonce: salt,
      info: label.codeUnits,
    );
    return Uint8List.fromList(await derived.extractBytes());
  }

  /// Derives the two cipher-layer subkeys plus the outer MAC and header keys.
  static Future<CascadeKeys> deriveCascadeKeys({
    required Uint8List rootKey,
    required Uint8List salt,
  }) async {
    final aes = await expand(rootKey: rootKey, label: _labelAes, salt: salt);
    final chacha = await expand(rootKey: rootKey, label: _labelChacha, salt: salt);
    final hmac = await expand(rootKey: rootKey, label: _labelHmac, salt: salt);
    final headerMac = await expand(rootKey: rootKey, label: _labelHeaderMac, salt: salt);
    return CascadeKeys(
      aesKey: aes,
      chachaKey: chacha,
      hmacKey: hmac,
      headerMacKey: headerMac,
    );
  }

  /// Key used to authenticate per-file chunk indices and lengths.
  static Future<Uint8List> deriveStreamKey({
    required Uint8List rootKey,
    required Uint8List salt,
  }) =>
      expand(rootKey: rootKey, label: _labelStream, salt: salt);

  /// Key used for the blind index that lets the vault search by name without
  /// ever storing a plaintext name.
  static Future<Uint8List> deriveNameKey({
    required Uint8List rootKey,
    required Uint8List salt,
  }) =>
      expand(rootKey: rootKey, label: _labelNameKey, salt: salt);
}
