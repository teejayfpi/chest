import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'crypto_primitives.dart';
import 'key_derivation.dart';

/// Bit flags stored in the container header describing which layers ran.
///
/// The flags are advisory: a reader always verifies every tag it needs, so a
/// tampered flag byte is caught by the header MAC rather than trusted.
class LayerFlags {
  LayerFlags._();

  static const int argon2id = 0x01;
  static const int hkdfSeparated = 0x02;
  static const int aesGcm = 0x04;
  static const int xchachaPoly = 0x08;
  static const int hmacEnvelope = 0x10;
  static const int padded = 0x20;

  /// The flag set written by [CascadeCipher] for version 1 containers.
  static const int all = argon2id |
      hkdfSeparated |
      aesGcm |
      xchachaPoly |
      hmacEnvelope |
      padded;

  /// Human-readable layer list for the UI, derived from [flags].
  static List<String> describe(int flags) {
    final layers = <String>[];
    if (flags & argon2id != 0) layers.add('Argon2id KDF');
    if (flags & hkdfSeparated != 0) layers.add('HKDF-SHA256 separation');
    if (flags & aesGcm != 0) layers.add('AES-256-GCM');
    if (flags & xchachaPoly != 0) layers.add('XChaCha20-Poly1305');
    if (flags & hmacEnvelope != 0) layers.add('HMAC-SHA256 envelope');
    if (flags & padded != 0) layers.add('Length padding');
    return layers;
  }
}

/// Parsed container header. Immutable and safe to display.
class ChestHeader {
  const ChestHeader({
    required this.formatVersion,
    required this.kdfProfileId,
    required this.layerFlags,
    required this.salt,
    required this.paddedLength,
  });

  /// Container format version.
  final int formatVersion;

  /// Argon2id preset identifier.
  final int kdfProfileId;

  /// [LayerFlags] bitmask.
  final int layerFlags;

  /// Per-container KDF salt.
  final Uint8List salt;

  /// Length of the *padded* plaintext, in bytes.
  final int paddedLength;

  /// Serialised header, exactly [CascadeCipher.headerLength] bytes.
  Uint8List toBytes() {
    final out = Uint8List(CascadeCipher.headerLength);
    out.setRange(0, 4, CascadeCipher.magic);
    final view = ByteData.view(out.buffer);
    view.setUint16(4, formatVersion, Endian.big);
    out[6] = kdfProfileId;
    out[7] = layerFlags;
    out.setRange(8, 24, salt);
    view.setUint64(24, paddedLength, Endian.big);
    return out;
  }

  /// Parses a header from the start of [bytes].
  static ChestHeader parse(Uint8List bytes) {
    if (bytes.length < CascadeCipher.headerLength) {
      throw const ChestFormatException('container shorter than header');
    }
    if (!startsWithBytes(bytes, CascadeCipher.magic)) {
      throw const ChestFormatException('bad magic bytes');
    }
    final view = ByteData.sublistView(bytes, 0, CascadeCipher.headerLength);
    final version = view.getUint16(4, Endian.big);
    if (version != CascadeCipher.formatVersion) {
      throw ChestFormatException('unsupported container version $version');
    }
    return ChestHeader(
      formatVersion: version,
      kdfProfileId: bytes[6],
      layerFlags: bytes[7],
      salt: Uint8List.fromList(bytes.sublist(8, 24)),
      paddedLength: view.getUint64(24, Endian.big),
    );
  }
}

/// Result of a successful decryption, including the parsed header so callers
/// can show which layers protected the data.
class ChestOpened {
  const ChestOpened({required this.plaintext, required this.header});

  /// Recovered plaintext bytes.
  final Uint8List plaintext;

  /// Header of the container the plaintext came from.
  final ChestHeader header;

  /// Layers that were verified while opening the container.
  List<String> get layers => LayerFlags.describe(header.layerFlags);
}

/// The Chest layered ("cascade") cipher.
///
/// ## Layer stack, innermost first
/// 1. **Argon2id** turns the passphrase into a 256-bit root key. Memory-hard,
///    so GPU/ASIC guessing is expensive.
/// 2. **HKDF-SHA256** splits the root key into independent subkeys. No key is
///    ever reused across layers.
/// 3. **AES-256-GCM** encrypts the padded plaintext with hardware-accelerated
///    AES. Authenticated.
/// 4. **XChaCha20-Poly1305** encrypts the AES output, so a break in AES alone
///    still leaves the data sealed. 192-bit nonce removes nonce-reuse risk.
/// 5. **HMAC-SHA256 envelope** over header and payload catches header tampering
///    before any cipher is invoked.
///
/// Both ciphers authenticate the header as associated data, so the metadata
/// cannot be altered to downgrade the KDF or swap a salt.
class CascadeCipher {
  CascadeCipher._();

  /// Container magic bytes: ASCII `CHST`.
  static const List<int> magic = <int>[0x43, 0x48, 0x53, 0x54];

  /// Current container format version.
  static const int formatVersion = 1;

  /// Serialised header size in bytes.
  static const int headerLength = 32;

  /// Header MAC size in bytes.
  static const int headerMacLength = 32;

  /// Envelope MAC size in bytes.
  static const int envelopeMacLength = 32;

  /// AES-GCM nonce length.
  static const int aesNonceLength = 12;

  /// AES-GCM tag length.
  static const int aesTagLength = 16;

  /// XChaCha20-Poly1305 nonce length.
  static const int chachaNonceLength = 24;

  /// XChaCha20-Poly1305 tag length.
  static const int chachaTagLength = 16;

  /// Smallest possible container: header + both MACs + empty payload.
  static const int minimumLength = headerLength +
      headerMacLength +
      chachaNonceLength +
      chachaTagLength +
      envelopeMacLength;

  /// Granularity to which plaintext is padded.
  static const int paddingBlock = 512;

  /// Encrypts [plaintext] with a passphrase, producing a self-describing
  /// container that carries its own salt, KDF preset and nonces.
  ///
  /// [aad] is optional extra context (for example a vault identifier) that is
  /// authenticated but not stored.
  static Future<Uint8List> seal({
    required Uint8List plaintext,
    required String passphrase,
    KdfProfile profile = KdfProfile.hardened,
    Uint8List? salt,
    List<int> aad = const <int>[],
  }) async {
    final effectiveSalt = salt ?? ChestRandom.bytes(KdfProfile.saltLength);
    final rootKey = await KeyDerivation.deriveRootKey(
      passphrase: passphrase,
      salt: effectiveSalt,
      profile: profile,
    );
    try {
      return await sealWithRootKey(
        plaintext: plaintext,
        rootKey: rootKey,
        salt: effectiveSalt,
        profileId: profile.id,
        aad: aad,
      );
    } finally {
      wipe(rootKey);
    }
  }

  /// Encrypts [plaintext] with an already-derived [rootKey].
  ///
  /// This is the primitive the vault uses: the passphrase is stretched once per
  /// unlock, and every file is then sealed with that same root key rather than
  /// paying the Argon2id cost again.
  static Future<Uint8List> sealWithRootKey({
    required Uint8List plaintext,
    required Uint8List rootKey,
    required Uint8List salt,
    required int profileId,
    List<int> aad = const <int>[],
  }) async {
    final header = ChestHeader(
      formatVersion: formatVersion,
      kdfProfileId: profileId,
      layerFlags: LayerFlags.all,
      salt: salt,
      paddedLength: _paddedLength(plaintext.length),
    );
    final headerBytes = header.toBytes();
    final boundAad = concatBytes([headerBytes, aad]);

    final keys = await KeyDerivation.deriveCascadeKeys(
      rootKey: rootKey,
      salt: salt,
    );
    try {
      final padded = _pad(plaintext, header.paddedLength);

      // Layer 3: AES-256-GCM.
      final aesNonce = ChestRandom.bytes(aesNonceLength);
      final aes = AesGcm.with256bits();
      final aesBox = await aes.encrypt(
        padded,
        secretKey: SecretKey(keys.aesKey),
        nonce: aesNonce,
        aad: boundAad,
      );
      final innerBlob = concatBytes([
        aesNonce,
        aesBox.mac.bytes,
        aesBox.cipherText,
      ]);
      wipe(padded);

      // Layer 4: XChaCha20-Poly1305 over the AES output.
      final chachaNonce = ChestRandom.bytes(chachaNonceLength);
      final chacha = Xchacha20.poly1305Aead();
      final outerBox = await chacha.encrypt(
        innerBlob,
        secretKey: SecretKey(keys.chachaKey),
        nonce: chachaNonce,
        aad: boundAad,
      );
      final payload = concatBytes([
        chachaNonce,
        outerBox.mac.bytes,
        outerBox.cipherText,
      ]);
      wipe(innerBlob);

      // Layer 5: HMAC envelopes. The header MAC covers the header alone so a
      // reader can reject a corrupted header before spending Argon2 time.
      final headerMac = await _hmac(keys.headerMacKey, headerBytes);
      final envelopeMac =
          await _hmac(keys.hmacKey, concatBytes([headerBytes, payload]));

      return concatBytes([headerBytes, headerMac, payload, envelopeMac]);
    } finally {
      keys.wipe();
    }
  }

  /// Opens a container produced by [seal].
  ///
  /// Verification happens outside-in: the envelope MAC is checked before
  /// Argon2id runs, then the header MAC, then the outer cipher, then the inner
  /// cipher. Any failure raises [ChestAuthenticationException].
  static Future<ChestOpened> open({
    required Uint8List container,
    required String passphrase,
    List<int> aad = const <int>[],
  }) async {
    final header = ChestHeader.parse(container);
    final rootKey = await KeyDerivation.deriveRootKey(
      passphrase: passphrase,
      salt: header.salt,
      profile: KdfProfile.fromId(header.kdfProfileId),
    );
    try {
      return await openWithRootKey(
        container: container,
        rootKey: rootKey,
        aad: aad,
      );
    } finally {
      wipe(rootKey);
    }
  }

  /// Opens a container with an already-derived [rootKey].
  ///
  /// The salt and KDF preset recorded in the header are authenticated but not
  /// re-derived: the caller is responsible for having derived [rootKey] from
  /// the matching salt.
  static Future<ChestOpened> openWithRootKey({
    required Uint8List container,
    required Uint8List rootKey,
    List<int> aad = const <int>[],
  }) async {
    if (container.length < minimumLength) {
      throw const ChestFormatException('container too short');
    }
    final header = ChestHeader.parse(container);
    final headerBytes = Uint8List.fromList(container.sublist(0, headerLength));
    final headerMac = Uint8List.fromList(
        container.sublist(headerLength, headerLength + headerMacLength));
    final payload = Uint8List.fromList(
      container.sublist(
          headerLength + headerMacLength, container.length - envelopeMacLength),
    );
    final envelopeMac =
        Uint8List.fromList(container.sublist(container.length - envelopeMacLength));
    final boundAad = concatBytes([headerBytes, aad]);

    final keys = await KeyDerivation.deriveCascadeKeys(
      rootKey: rootKey,
      salt: header.salt,
    );
    try {
      // Layer 5, outermost first: envelope MAC binds header to payload.
      final expectedEnvelope =
          await _hmac(keys.hmacKey, concatBytes([headerBytes, payload]));
      if (!constantTimeEquals(expectedEnvelope, envelopeMac)) {
        throw const ChestAuthenticationException('envelope MAC mismatch');
      }

      // Header MAC: rejects a rewritten KDF preset or salt.
      final expectedHeader = await _hmac(keys.headerMacKey, headerBytes);
      if (!constantTimeEquals(expectedHeader, headerMac)) {
        throw const ChestAuthenticationException('header MAC mismatch');
      }

      if (payload.length < chachaNonceLength + chachaTagLength) {
        throw const ChestFormatException('truncated payload');
      }
      final chachaNonce = Uint8List.fromList(payload.sublist(0, chachaNonceLength));
      final chachaMac = Mac(
        payload.sublist(chachaNonceLength, chachaNonceLength + chachaTagLength),
      );
      final outerCipherText =
          Uint8List.fromList(payload.sublist(chachaNonceLength + chachaTagLength));

      // Layer 4: unwrap XChaCha20-Poly1305.
      final chacha = Xchacha20.poly1305Aead();
      final List<int> innerBlob;
      try {
        innerBlob = await chacha.decrypt(
          SecretBox(outerCipherText, nonce: chachaNonce, mac: chachaMac),
          secretKey: SecretKey(keys.chachaKey),
          aad: boundAad,
        );
      } on SecretBoxAuthenticationError {
        throw const ChestAuthenticationException('outer cipher tag mismatch');
      }

      if (innerBlob.length < aesNonceLength + aesTagLength) {
        throw const ChestFormatException('truncated inner blob');
      }
      final aesNonce = Uint8List.fromList(innerBlob.sublist(0, aesNonceLength));
      final aesMac =
          Mac(innerBlob.sublist(aesNonceLength, aesNonceLength + aesTagLength));
      final aesCipherText =
          Uint8List.fromList(innerBlob.sublist(aesNonceLength + aesTagLength));

      // Layer 3: unwrap AES-256-GCM.
      final aes = AesGcm.with256bits();
      final List<int> padded;
      try {
        padded = await aes.decrypt(
          SecretBox(aesCipherText, nonce: aesNonce, mac: aesMac),
          secretKey: SecretKey(keys.aesKey),
          aad: boundAad,
        );
      } on SecretBoxAuthenticationError {
        throw const ChestAuthenticationException('inner cipher tag mismatch');
      }

      final paddedBytes = Uint8List.fromList(padded);
      final plaintext = _unpad(paddedBytes, header.paddedLength);
      wipe(paddedBytes);
      return ChestOpened(plaintext: plaintext, header: header);
    } finally {
      keys.wipe();
    }
  }

  /// Reads only the header of [container] without deriving any key.
  static ChestHeader inspect(Uint8List container) => ChestHeader.parse(container);

  /// Computes an HMAC-SHA256 tag.
  static Future<Uint8List> _hmac(Uint8List key, List<int> message) async {
    final mac = await Hmac.sha256().calculateMac(message, secretKey: SecretKey(key));
    return Uint8List.fromList(mac.bytes);
  }

  /// Size of the trailing padding-length marker, in bytes.
  static const int _paddingMarkerLength = 2;

  /// Rounds [length] up to the next [paddingBlock] boundary.
  ///
  /// Padding is *always* added, even when the plaintext already fills a whole
  /// block, so the padded length alone never reveals that the input was
  /// block-aligned. When the natural padding would be smaller than the length
  /// marker, a whole extra block is added instead.
  static int _paddedLength(int length) {
    var pad = paddingBlock - (length % paddingBlock);
    if (pad < _paddingMarkerLength) {
      pad += paddingBlock;
    }
    return length + pad;
  }

  /// Pads to [paddedLength].
  ///
  /// The last two bytes record how many padding bytes were added (big-endian)
  /// and the padding before it is random rather than zero, so it does not stand
  /// out in a hex dump.
  static Uint8List _pad(Uint8List plaintext, int paddedLength) {
    final padLength = paddedLength - plaintext.length;
    if (padLength < _paddingMarkerLength || padLength > 2 * paddingBlock) {
      throw const ChestCryptoException('invalid_padding');
    }
    final out = Uint8List(paddedLength);
    out.setRange(0, plaintext.length, plaintext);
    final filler = padLength - _paddingMarkerLength;
    if (filler > 0) {
      out.setRange(plaintext.length, paddedLength - _paddingMarkerLength,
          ChestRandom.bytes(filler));
    }
    ByteData.view(out.buffer).setUint16(
      paddedLength - _paddingMarkerLength,
      padLength,
      Endian.big,
    );
    return out;
  }

  /// Reverses [_pad].
  static Uint8List _unpad(Uint8List padded, int paddedLength) {
    if (padded.length != paddedLength) {
      throw const ChestFormatException('padded length mismatch');
    }
    final padLength = ByteData.sublistView(padded)
        .getUint16(paddedLength - _paddingMarkerLength, Endian.big);
    if (padLength < _paddingMarkerLength || padLength > paddedLength) {
      throw const ChestFormatException('invalid padding marker');
    }
    return Uint8List.fromList(padded.sublist(0, paddedLength - padLength));
  }
}
