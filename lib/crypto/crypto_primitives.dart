import 'dart:math';
import 'dart:typed_data';

/// Base class for every failure raised by the Chest cryptography stack.
///
/// Messages stay deliberately terse: callers surface a generic "could not
/// unlock" string to the user, so nothing here may leak plaintext or key
/// material.
class ChestCryptoException implements Exception {
  const ChestCryptoException(this.code, [this.detail]);

  /// Stable machine-readable identifier, safe to log.
  final String code;

  /// Optional human-readable detail. Never contains secret material.
  final String? detail;

  @override
  String toString() =>
      detail == null ? 'ChestCryptoException($code)' : 'ChestCryptoException($code): $detail';
}

/// True when [error] is a Chest crypto failure with the given [code].
///
/// Callers should branch on this rather than on `toString()`, because
/// [ChestCryptoException.toString] deliberately prints the base class name for
/// every subclass, so a message match would silently miss the subclass type.
bool isChestError(Object? error, String code) =>
    error is ChestCryptoException && error.code == code;

/// Raised when an authentication tag, HMAC or header check fails.
///
/// A single exception type covers *all* verification failures so an attacker
/// cannot use error distinctions as an oracle.
class ChestAuthenticationException extends ChestCryptoException {
  const ChestAuthenticationException([String? detail])
      : super('authentication_failed', detail);
}

/// Raised when a container cannot be parsed at all.
class ChestFormatException extends ChestCryptoException {
  const ChestFormatException([String? detail]) : super('malformed_container', detail);
}

/// Cryptographically strong randomness plus byte helpers shared by the crypto
/// layer.
class ChestRandom {
  ChestRandom._();

  static final Random _secure = Random.secure();

  /// Returns [length] cryptographically secure random bytes.
  static Uint8List bytes(int length) {
    if (length < 0) {
      throw ArgumentError.value(length, 'length', 'must not be negative');
    }
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _secure.nextInt(256);
    }
    return out;
  }
}

/// Length-independent comparison of two byte sequences.
///
/// Used for every secret-dependent comparison so timing does not reveal where
/// two sequences diverge.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Overwrites [bytes] with zeros.
///
/// Dart cannot guarantee the collector has not already copied a buffer, but
/// zeroing still shrinks the window during which derived key material sits in
/// the heap.
void wipe(Uint8List bytes) {
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = 0;
  }
}

/// Concatenates byte sequences into a single [Uint8List].
Uint8List concatBytes(Iterable<List<int>> parts) {
  final builder = BytesBuilder(copy: false);
  for (final part in parts) {
    builder.add(part);
  }
  return builder.takeBytes();
}

/// Encodes a 32-bit big-endian unsigned integer.
Uint8List uint32be(int value) {
  final out = Uint8List(4);
  ByteData.view(out.buffer).setUint32(0, value, Endian.big);
  return out;
}

/// Encodes a 64-bit big-endian unsigned integer.
Uint8List uint64be(int value) {
  final out = Uint8List(8);
  ByteData.view(out.buffer).setUint64(0, value, Endian.big);
  return out;
}

/// Decodes a 32-bit big-endian unsigned integer from [bytes] at [offset].
int readUint32be(List<int> bytes, int offset) =>
    ByteData.sublistView(Uint8List.fromList(bytes), offset, offset + 4)
        .getUint32(0, Endian.big);

/// Renders bytes as lowercase hexadecimal.
String hexEncode(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// Decodes lowercase or uppercase hexadecimal into bytes.
///
/// Throws [ChestFormatException] on odd length or non-hex input.
Uint8List hexDecode(String value) {
  if (value.length.isOdd) {
    throw const ChestFormatException('hex string has odd length');
  }
  final out = Uint8List(value.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final byte = int.tryParse(value.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) {
      throw const ChestFormatException('hex string contains non-hex characters');
    }
    out[i] = byte;
  }
  return out;
}

/// Fixed-time-length prefix comparison used by the container parser.
bool startsWithBytes(List<int> data, List<int> prefix) {
  if (data.length < prefix.length) return false;
  return constantTimeEquals(data.sublist(0, prefix.length), prefix);
}
