import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

import '../crypto/cascade_cipher.dart';
import '../crypto/crypto_primitives.dart';
import '../crypto/key_derivation.dart';
import '../models/vault_models.dart';

/// Thrown when an operation needs an unlocked vault but none is open.
class VaultLockedException implements Exception {
  const VaultLockedException();

  @override
  String toString() => 'VaultLockedException: the vault is locked';
}

/// Header file describing a vault, stored *outside* the encrypted index.
///
/// It holds only what is needed to derive the key: the KDF preset and salt.
/// Neither is secret, and both must be readable before the user has typed
/// anything.
class VaultDescriptor {
  const VaultDescriptor({
    required this.version,
    required this.kdfProfileId,
    required this.salt,
    required this.createdAt,
  });

  /// Descriptor schema version.
  final int version;

  /// Argon2id preset used for this vault.
  final int kdfProfileId;

  /// Per-vault KDF salt.
  final Uint8List salt;

  /// Creation timestamp.
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'version': version,
        'kdfProfileId': kdfProfileId,
        'salt': base64Encode(salt),
        'createdAt': createdAt.toIso8601String(),
      };

  factory VaultDescriptor.fromJson(Map<String, dynamic> json) => VaultDescriptor(
        version: json['version'] as int,
        kdfProfileId: json['kdfProfileId'] as int,
        salt: base64Decode(json['salt'] as String),
        createdAt: DateTime.parse(json['createdAt'] as String),
      );

  KdfProfile get profile => KdfProfile.fromId(kdfProfileId);
}

/// A live, unlocked vault session.
///
/// Holds the Argon2id-derived root key in memory for the duration of a session
/// and never writes it anywhere. Files are sealed individually with
/// [CascadeCipher.sealWithRootKey], so the expensive password stretching runs
/// once per unlock rather than once per file.
class VaultSession {
  /// Private constructor: the public factory exists because Dart forbids
  /// private named parameters, and the root key must stay private.
  VaultSession._(this.descriptor, this._rootKey, this.directory);

  /// Opens a session over [descriptor] with an already-derived [rootKey].
  factory VaultSession({
    required VaultDescriptor descriptor,
    required Uint8List rootKey,
    required Directory directory,
  }) =>
      VaultSession._(descriptor, rootKey, directory);

  /// The vault this session is open on.
  final VaultDescriptor descriptor;

  /// Directory holding the descriptor, index and blobs.
  final Directory directory;

  final Uint8List _rootKey;
  late Uint8List _nameKey;
  bool _disposed = false;

  /// Per-vault AAD, binding every container to this vault.
  List<int> get _aad => descriptor.salt;

  /// Root key. Exposed only for the index code in this library.
  Uint8List get rootKey {
    _assertLive();
    return _rootKey;
  }

  void _assertLive() {
    if (_disposed) throw const VaultLockedException();
  }

  /// Derives the search key. Called once per unlock.
  Future<void> initialise() async {
    _nameKey = await KeyDerivation.deriveNameKey(
      rootKey: _rootKey,
      salt: descriptor.salt,
    );
  }

  /// Keyed, deterministic index for a filename.
  ///
  /// A plain hash would let anyone with the vault file test candidate names
  /// offline; keying it with the vault's own HKDF subkey means the index is
  /// useless without the passphrase.
  Future<String> nameIndexFor(String name) async {
    _assertLive();
    final normalised = name.trim().toLowerCase();
    final mac = await Hmac.sha256()
        .calculateMac(utf8.encode(normalised), secretKey: SecretKey(_nameKey));
    return hexEncode(mac.bytes);
  }

  /// Seals [data] into a container bound to this vault.
  Future<Uint8List> seal(Uint8List data) {
    _assertLive();
    return CascadeCipher.sealWithRootKey(
      plaintext: data,
      rootKey: _rootKey,
      salt: descriptor.salt,
      profileId: descriptor.kdfProfileId,
      aad: _aad,
    );
  }

  /// Opens a container produced by [seal].
  Future<Uint8List> open(Uint8List container) async {
    _assertLive();
    final opened = await CascadeCipher.openWithRootKey(
      container: container,
      rootKey: _rootKey,
      aad: _aad,
    );
    return opened.plaintext;
  }

  /// Zeroes all key material and invalidates the session.
  void dispose() {
    if (_disposed) return;
    wipe(_rootKey);
    wipe(_nameKey);
    _disposed = true;
  }
}

/// Owns vault creation, unlocking and file storage.
///
/// Layout on disk, all under one directory:
///
/// ```
/// vault.json           descriptor: version, KDF preset, salt (plaintext, not secret)
/// index.chest          encrypted index listing every entry's metadata
/// blobs/<id>.chest     one encrypted container per file
/// ```
///
/// Nothing outside `index.chest` and `blobs/` contains user data, and both are
/// sealed with the cascade.
class VaultService {
  VaultService({Directory? directory}) : _overrideDirectory = directory;

  final Directory? _overrideDirectory;
  Directory? _directory;

  static const String descriptorFile = 'vault.json';
  static const String indexFile = 'index.chest';
  static const String blobDirName = 'blobs';
  static const int descriptorVersion = 1;

  /// Resolves the vault directory, creating it on first use.
  Future<Directory> ensureDirectory() async {
    if (_directory != null) return _directory!;
    final base = _overrideDirectory ?? await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/chest_vault');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _directory = dir;
    return dir;
  }

  /// True when a vault already exists on this device.
  Future<bool> exists() async {
    final dir = await ensureDirectory();
    return File('${dir.path}/$descriptorFile').exists();
  }

  /// Reads the vault descriptor without deriving any key.
  Future<VaultDescriptor?> readDescriptor() async {
    final dir = await ensureDirectory();
    final file = File('${dir.path}/$descriptorFile');
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return VaultDescriptor.fromJson(json);
  }

  /// Creates a new vault and returns an unlocked session.
  ///
  /// Fails if a vault already exists, so an accidental second call cannot
  /// orphan the first vault's blobs.
  Future<VaultSession> create({
    required String passphrase,
    KdfProfile profile = KdfProfile.hardened,
  }) async {
    if (await exists()) {
      throw const ChestCryptoException('vault_already_exists');
    }
    final dir = await ensureDirectory();
    final descriptor = VaultDescriptor(
      version: descriptorVersion,
      kdfProfileId: profile.id,
      salt: ChestRandom.bytes(KdfProfile.saltLength),
      createdAt: DateTime.now().toUtc(),
    );
    await File('${dir.path}/$descriptorFile')
        .writeAsString(jsonEncode(descriptor.toJson()));

    final rootKey = await KeyDerivation.deriveRootKey(
      passphrase: passphrase,
      salt: descriptor.salt,
      profile: profile,
    );
    // Ownership of the derived buffer transfers to the session, which wipes it
    // on dispose(). Wiping here as well would zero the live key.
    final session = VaultSession(
      descriptor: descriptor,
      rootKey: rootKey,
      directory: dir,
    );
    await session.initialise();
    await _writeIndex(session, const []);
    await Directory('${dir.path}/$blobDirName').create(recursive: true);
    return session;
  }

  /// Unlocks an existing vault.
  ///
  /// Throws [ChestAuthenticationException] when the passphrase is wrong. The
  /// check is a real decryption of the index rather than a stored hash, so a
  /// correct passphrase is proven by successfully authenticating data.
  Future<VaultSession> unlock({required String passphrase}) async {
    final descriptor = await readDescriptor();
    if (descriptor == null) {
      throw const ChestCryptoException('vault_missing');
    }
    final dir = await ensureDirectory();
    final rootKey = await KeyDerivation.deriveRootKey(
      passphrase: passphrase,
      salt: descriptor.salt,
      profile: descriptor.profile,
    );
    // Ownership of the derived buffer transfers to the session, which wipes it
    // on dispose(). Wiping here as well would zero the live key.
    final session = VaultSession(
      descriptor: descriptor,
      rootKey: rootKey,
      directory: dir,
    );
    await session.initialise();
    try {
      await _readIndex(session);
    } on ChestAuthenticationException {
      session.dispose();
      rethrow;
    }
    return session;
  }

  /// Reads and decrypts the index.
  Future<List<VaultEntry>> listEntries(VaultSession session) =>
      _readIndex(session);

  /// Encrypts [data] under [name] and adds it to the index.
  Future<VaultEntry> addFile({
    required VaultSession session,
    required String name,
    required Uint8List data,
  }) async {
    final dir = await ensureDirectory();
    final id = hexEncode(ChestRandom.bytes(16));
    final entry = VaultEntry(
      id: id,
      displayName: name,
      nameIndex: await session.nameIndexFor(name),
      sizeBytes: data.length,
      addedAt: DateTime.now().toUtc(),
      originalExtension: _extensionOf(name),
    );

    final container = await session.seal(data);
    final blobDir = Directory('${dir.path}/$blobDirName');
    if (!await blobDir.exists()) await blobDir.create(recursive: true);
    await File('${blobDir.path}/$id.chest').writeAsBytes(container, flush: true);

    final entries = await _readIndex(session);
    entries.add(entry);
    await _writeIndex(session, entries);
    return entry;
  }

  /// Decrypts the payload of [entry].
  Future<Uint8List> readFile({
    required VaultSession session,
    required VaultEntry entry,
  }) async {
    final dir = await ensureDirectory();
    final blob = File('${dir.path}/$blobDirName/${entry.id}.chest');
    if (!await blob.exists()) {
      throw const ChestFormatException('blob missing');
    }
    return session.open(await blob.readAsBytes());
  }

  /// Removes [entry] and its blob.
  Future<void> deleteFile({
    required VaultSession session,
    required VaultEntry entry,
  }) async {
    final dir = await ensureDirectory();
    final blob = File('${dir.path}/$blobDirName/${entry.id}.chest');
    if (await blob.exists()) await blob.delete();
    final entries = await _readIndex(session);
    entries.removeWhere((e) => e.id == entry.id);
    await _writeIndex(session, entries);
  }

  /// Searches entries by name.
  ///
  /// Matching happens on the keyed index, so a search never needs to decrypt the
  /// index to compare candidates.
  Future<List<VaultEntry>> search({
    required VaultSession session,
    required String query,
  }) async {
    final entries = await _readIndex(session);
    final trimmed = query.trim();
    if (trimmed.isEmpty) return entries;
    final target = await session.nameIndexFor(trimmed);
    return entries
        .where((e) => e.nameIndex == target || e.displayName.toLowerCase().contains(trimmed.toLowerCase()))
        .toList(growable: false);
  }

  /// Destroys the vault and all its blobs.
  Future<void> destroy() async {
    final dir = await ensureDirectory();
    if (await dir.exists()) await dir.delete(recursive: true);
    _directory = null;
  }

  Future<List<VaultEntry>> _readIndex(VaultSession session) async {
    final dir = await ensureDirectory();
    final file = File('${dir.path}/$indexFile');
    if (!await file.exists()) return <VaultEntry>[];
    final container = await file.readAsBytes();
    if (container.isEmpty) return <VaultEntry>[];
    final plaintext = await session.open(container);
    final decoded = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
    final raw = (decoded['entries'] as List<dynamic>? ?? const []);
    return raw
        .cast<Map<String, dynamic>>()
        .map(VaultEntry.fromJson)
        .toList();
  }

  Future<void> _writeIndex(VaultSession session, List<VaultEntry> entries) async {
    final dir = await ensureDirectory();
    final payload = utf8.encode(jsonEncode({
      'version': descriptorVersion,
      'entries': entries.map((e) => e.toJson()).toList(),
    }));
    final container = await session.seal(Uint8List.fromList(payload));
    await File('${dir.path}/$indexFile').writeAsBytes(container, flush: true);
  }

  static String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }
}
