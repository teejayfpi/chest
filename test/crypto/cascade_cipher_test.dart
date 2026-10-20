import 'dart:typed_data';

import 'package:chest/crypto/cascade_cipher.dart';
import 'package:chest/crypto/crypto_primitives.dart';
import 'package:chest/crypto/key_derivation.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bytesOf(String s) => Uint8List.fromList(s.codeUnits);

Uint8List pattern(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i * 7 + 13) & 0xff));

void main() {
  group('byte helpers', () {
    test('constantTimeEquals matches only identical sequences', () {
      expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
      expect(constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
      expect(constantTimeEquals([1, 2], [1, 2, 3]), isFalse);
      expect(constantTimeEquals([], []), isTrue);
    });

    test('hex round-trips', () {
      final bytes = ChestRandom.bytes(32);
      expect(hexDecode(hexEncode(bytes)), equals(bytes));
    });

    test('hexDecode rejects malformed input', () {
      expect(() => hexDecode('abc'), throwsA(isA<ChestFormatException>()));
      expect(() => hexDecode('zz'), throwsA(isA<ChestFormatException>()));
    });

    test('wipe zeroes a buffer in place', () {
      final buffer = Uint8List.fromList([1, 2, 3, 4]);
      wipe(buffer);
      expect(buffer, equals([0, 0, 0, 0]));
    });

    test('uint32be and readUint32be round-trip', () {
      for (final value in [0, 1, 255, 65535, 4294967295]) {
        expect(readUint32be(uint32be(value), 0), equals(value));
      }
    });
  });

  group('key derivation', () {
    test('is deterministic for the same salt and passphrase', () async {
      final salt = ChestRandom.bytes(KdfProfile.saltLength);
      final a = await KeyDerivation.deriveRootKey(
        passphrase: 'correct horse battery staple',
        salt: salt,
        profile: KdfProfile.standard,
      );
      final b = await KeyDerivation.deriveRootKey(
        passphrase: 'correct horse battery staple',
        salt: salt,
        profile: KdfProfile.standard,
      );
      expect(a, equals(b));
      expect(a.length, equals(KeyDerivation.rootKeyLength));
    });

    test('changes when the salt changes', () async {
      final a = await KeyDerivation.deriveRootKey(
        passphrase: 'same',
        salt: ChestRandom.bytes(KdfProfile.saltLength),
        profile: KdfProfile.standard,
      );
      final b = await KeyDerivation.deriveRootKey(
        passphrase: 'same',
        salt: ChestRandom.bytes(KdfProfile.saltLength),
        profile: KdfProfile.standard,
      );
      expect(a, isNot(equals(b)));
    });

    test('rejects a short salt', () async {
      await expectLater(
        KeyDerivation.deriveRootKey(
          passphrase: 'x',
          salt: Uint8List(8),
          profile: KdfProfile.standard,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects an empty passphrase', () async {
      await expectLater(
        KeyDerivation.deriveRootKey(
          passphrase: '',
          salt: ChestRandom.bytes(KdfProfile.saltLength),
          profile: KdfProfile.standard,
        ),
        throwsA(isA<ChestCryptoException>()),
      );
    });

    test('separates subkeys by label', () async {
      final root = ChestRandom.bytes(32);
      final salt = ChestRandom.bytes(KdfProfile.saltLength);
      final keys = await KeyDerivation.deriveCascadeKeys(rootKey: root, salt: salt);
      final distinct = <String>{
        hexEncode(keys.aesKey),
        hexEncode(keys.chachaKey),
        hexEncode(keys.hmacKey),
        hexEncode(keys.headerMacKey),
      };
      expect(distinct.length, equals(4),
          reason: 'each label must yield a unique key');
      expect(keys.aesKey.length, equals(32));
    });
  });

  group('cascade cipher', () {
    test('round-trips a small payload', () async {
      final plaintext = bytesOf('Chest keeps secrets.');
      final container = await CascadeCipher.seal(
        plaintext: plaintext,
        passphrase: 'hunter2',
        profile: KdfProfile.standard,
      );
      final opened = await CascadeCipher.open(
        container: container,
        passphrase: 'hunter2',
      );
      expect(opened.plaintext, equals(plaintext));
      expect(opened.layers, contains('AES-256-GCM'));
      expect(opened.layers, contains('XChaCha20-Poly1305'));
      expect(opened.layers, contains('Argon2id KDF'));
    });

    test('round-trips payloads on both sides of the padding block', () async {
      for (final length in [0, 1, 511, 512, 513, 1024, 5000]) {
        final plaintext = pattern(length);
        final container = await CascadeCipher.seal(
          plaintext: plaintext,
          passphrase: 'pw',
          profile: KdfProfile.standard,
        );
        final opened =
            await CascadeCipher.open(container: container, passphrase: 'pw');
        expect(opened.plaintext, equals(plaintext), reason: 'length $length');
      }
    });

    test('always pads, so an exact block is still padded', () async {
      final container = await CascadeCipher.seal(
        plaintext: pattern(512),
        passphrase: 'pw',
        profile: KdfProfile.standard,
      );
      final header = CascadeCipher.inspect(container);
      expect(header.paddedLength, equals(1024));
    });

    test('rejects a wrong passphrase', () async {
      final container = await CascadeCipher.seal(
        plaintext: bytesOf('secret'),
        passphrase: 'right',
        profile: KdfProfile.standard,
      );
      await expectLater(
        CascadeCipher.open(container: container, passphrase: 'wrong'),
        throwsA(isA<ChestAuthenticationException>()),
      );
    });

    test('rejects a flipped ciphertext bit', () async {
      final container = await CascadeCipher.seal(
        plaintext: bytesOf('secret payload'),
        passphrase: 'pw',
        profile: KdfProfile.standard,
      );
      final tampered = Uint8List.fromList(container);
      tampered[tampered.length - 60] ^= 0x01;
      await expectLater(
        CascadeCipher.open(container: tampered, passphrase: 'pw'),
        throwsA(isA<ChestAuthenticationException>()),
      );
    });

    test('rejects a downgraded KDF profile in the header', () async {
      final container = await CascadeCipher.seal(
        plaintext: bytesOf('secret payload'),
        passphrase: 'pw',
        profile: KdfProfile.hardened,
      );
      final tampered = Uint8List.fromList(container);
      tampered[6] = KdfProfile.standard.id;
      expect(
        () => CascadeCipher.open(container: tampered, passphrase: 'pw'),
        throwsA(isA<ChestAuthenticationException>()),
      );
    });

    test('rejects a swapped salt', () async {
      final container = await CascadeCipher.seal(
        plaintext: bytesOf('secret payload'),
        passphrase: 'pw',
        profile: KdfProfile.standard,
      );
      final tampered = Uint8List.fromList(container);
      tampered.setRange(8, 24, ChestRandom.bytes(16));
      expect(
        () => CascadeCipher.open(container: tampered, passphrase: 'pw'),
        throwsA(isA<ChestAuthenticationException>()),
      );
    });

    test('rejects truncated and malformed containers', () async {
      final container = await CascadeCipher.seal(
        plaintext: bytesOf('secret payload'),
        passphrase: 'pw',
        profile: KdfProfile.standard,
      );
      await expectLater(
        CascadeCipher.open(
          container: Uint8List.fromList(container.sublist(0, 20)),
          passphrase: 'pw',
        ),
        throwsA(isA<ChestCryptoException>()),
      );
      await expectLater(
        CascadeCipher.open(
          container: Uint8List.fromList(List.filled(container.length, 0)),
          passphrase: 'pw',
        ),
        throwsA(isA<ChestFormatException>()),
      );
    });

    test('binds associated data', () async {
      final container = await CascadeCipher.seal(
        plaintext: bytesOf('secret'),
        passphrase: 'pw',
        profile: KdfProfile.standard,
        aad: bytesOf('vault-A'),
      );
      final good = await CascadeCipher.open(
        container: container,
        passphrase: 'pw',
        aad: bytesOf('vault-A'),
      );
      expect(good.plaintext, equals(bytesOf('secret')));
      await expectLater(
        CascadeCipher.open(
          container: container,
          passphrase: 'pw',
          aad: bytesOf('vault-B'),
        ),
        throwsA(isA<ChestAuthenticationException>()),
      );
    });

    test('produces a different container each time', () async {
      final first = await CascadeCipher.seal(
        plaintext: bytesOf('same input'),
        passphrase: 'pw',
        profile: KdfProfile.standard,
      );
      final second = await CascadeCipher.seal(
        plaintext: bytesOf('same input'),
        passphrase: 'pw',
        profile: KdfProfile.standard,
      );
      expect(first, isNot(equals(second)));
    });

    test('does not leak the plaintext into the container', () async {
      final marker = 'UNIQUE-PLAINTEXT-MARKER-9F3A';
      final container = await CascadeCipher.seal(
        plaintext: bytesOf(marker),
        passphrase: 'pw',
        profile: KdfProfile.standard,
      );
      expect(hexEncode(container).contains(hexEncode(bytesOf(marker))), isFalse);
    });

    test('supports the hardened profile', () async {
      final plaintext = bytesOf('hardened');
      final container = await CascadeCipher.seal(
        plaintext: plaintext,
        passphrase: 'pw',
        profile: KdfProfile.hardened,
      );
      final opened =
          await CascadeCipher.open(container: container, passphrase: 'pw');
      expect(opened.plaintext, equals(plaintext));
      expect(opened.header.kdfProfileId, equals(KdfProfile.hardened.id));
    });
  });
}
