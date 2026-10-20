import 'package:flutter/services.dart';

/// A file the user chose in the system picker, before it is sealed.
///
/// [uri] is the handle to delete the original once the vault holds a sealed
/// copy. It is opaque and must not be parsed.
class PickedFile {
  const PickedFile({
    required this.uri,
    required this.name,
    required this.sizeBytes,
    required this.mimeType,
  });

  final String uri;
  final String name;

  /// Bytes, or -1 when the provider did not report a size.
  final int sizeBytes;

  final String mimeType;

  bool get sizeKnown => sizeBytes >= 0;

  static PickedFile fromMap(Map<dynamic, dynamic> map) => PickedFile(
        uri: map['uri'] as String? ?? '',
        name: map['name'] as String? ?? 'file',
        sizeBytes: (map['size'] as num?)?.toInt() ?? -1,
        mimeType: map['mimeType'] as String? ?? 'application/octet-stream',
      );
}

/// Why a pick or read failed, so the UI can say something useful.
class ChestFileException implements Exception {
  const ChestFileException(this.code);

  /// A stable code: `no_launcher`, `picker_failed`, `no_read_permission`,
  /// `file_too_large`, `unreadable` or `read_failed`.
  final String code;

  /// A message for the user, phrased for someone who is not reading a log.
  String get message => switch (code) {
        'no_launcher' => 'The file picker is not available on this device.',
        'picker_failed' => 'The file picker could not be opened.',
        'no_read_permission' =>
          'Chest was not allowed to read that file. Nothing was changed.',
        'file_too_large' =>
          'That file is too large for Chest to seal in one piece.',
        'unreadable' => 'That file could not be read. Nothing was changed.',
        _ => 'That file could not be read. Nothing was changed.',
      };

  @override
  String toString() => 'ChestFileException($code)';
}

/// Dart side of the native file-handling bridge.
///
/// Like [AppLockBridge], every call degrades instead of throwing, so the UI can
/// still render on a platform without the Android implementation and explain
/// what is missing.
class ChestFilesBridge {
  ChestFilesBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.chest.chest/files';

  final MethodChannel _channel;

  /// Opens the system picker and resolves with the chosen files.
  ///
  /// An empty list means the user cancelled, which is not an error. The picker
  /// grants Chest read and write on each file, so the original can be removed
  /// after sealing; see [deleteSource].
  Future<List<PickedFile>> pickFiles() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('pickFiles');
      if (raw == null) return const [];
      return raw
          .cast<Map<dynamic, dynamic>>()
          .map(PickedFile.fromMap)
          .where((f) => f.uri.isNotEmpty)
          .toList(growable: false);
    } on MissingPluginException {
      return const [];
    } on PlatformException catch (e) {
      throw ChestFileException(e.code);
    }
  }

  /// Reads the bytes of a picked file.
  ///
  /// The bytes cross the channel in one message because the vault seals in
  /// memory: writing them to a temporary file first would leave a plaintext
  /// copy outside the vault, which is the thing this path exists to avoid.
  Future<Uint8List> readPickedFile(String uri, {int? maxBytes}) async {
    try {
      final bytes = await _channel.invokeMethod<Uint8List>(
        'readPickedFile',
        {'uri': uri, 'maxBytes': ?maxBytes},
      );
      if (bytes == null) throw const ChestFileException('unreadable');
      return bytes;
    } on MissingPluginException {
      throw const ChestFileException('unreadable');
    } on PlatformException catch (e) {
      throw ChestFileException(e.code);
    }
  }

  /// Deletes the original of a file whose bytes are already sealed.
  ///
  /// Returns whether the original is genuinely gone. Callers must report a
  /// false result to the user: the file is safely in the vault either way, but
  /// leaving the original in the gallery means the content is still exposed.
  Future<bool> deleteSource(String uri) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'deleteSource',
        {'uri': uri},
      );
      return raw?['removed'] == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Drops the picker's grant once the original is gone or the user declined,
  /// so Chest does not keep standing access to a file it no longer needs.
  Future<void> releaseSource(String uri) async {
    try {
      await _channel.invokeMethod<bool>('releaseSource', {'uri': uri});
    } on MissingPluginException {
      // Nothing to release on a platform without the bridge.
    } on PlatformException {
      // A grant that cannot be released is not worth failing the flow over.
    }
  }

  /// Opens a chooser so the user can save or send a decrypted file.
  ///
  /// The caller owns [cachePath] and must delete it once the chooser returns.
  Future<bool> shareFile({
    required String cachePath,
    required String mimeType,
  }) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'shareFile',
        {'path': cachePath, 'mimeType': mimeType},
      );
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens the WhatsApp chat with [phone].
  ///
  /// Returns false when there is no usable number or WhatsApp is not installed,
  /// so the UI can fall back to showing the number to copy.
  Future<bool> openWhatsApp(String phone) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'openWhatsApp',
        {'phone': phone},
      );
      return raw?['opened'] == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
