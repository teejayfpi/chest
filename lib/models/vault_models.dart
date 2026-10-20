import 'dart:typed_data';

/// A file held inside the vault.
///
/// Only [id] and the encrypted blob ever touch the disk in plaintext form.
/// [displayName] is encrypted as part of the vault index, and [nameIndex] is a
/// keyed HMAC of the lowercased name so the vault can be searched without the
/// index being decrypted for every keystroke.
class VaultEntry {
  const VaultEntry({
    required this.id,
    required this.displayName,
    required this.nameIndex,
    required this.sizeBytes,
    required this.addedAt,
    required this.originalExtension,
  });

  /// Random identifier; also the on-disk blob filename.
  final String id;

  /// Original filename, as typed by the user.
  final String displayName;

  /// Keyed HMAC-SHA256 of the normalised name, used for lookups.
  final String nameIndex;

  /// Size of the *plaintext*, kept so the UI can show it without decrypting.
  final int sizeBytes;

  /// When the entry was added.
  final DateTime addedAt;

  /// Lowercased extension without the dot, or an empty string.
  final String originalExtension;

  /// Serialises to the JSON shape stored inside the encrypted index.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': displayName,
        'nameIndex': nameIndex,
        'size': sizeBytes,
        'addedAt': addedAt.toIso8601String(),
        'ext': originalExtension,
      };

  /// Parses the JSON shape produced by [toJson].
  factory VaultEntry.fromJson(Map<String, dynamic> json) => VaultEntry(
        id: json['id'] as String,
        displayName: json['name'] as String,
        nameIndex: json['nameIndex'] as String,
        sizeBytes: json['size'] as int,
        addedAt: DateTime.parse(json['addedAt'] as String),
        originalExtension: (json['ext'] as String?) ?? '',
      );
}

/// An Android app the user can freeze.
class FreezableApp {
  const FreezableApp({
    required this.packageName,
    required this.label,
    required this.isSystem,
    required this.frozen,
  });

  /// Android package identifier.
  final String packageName;

  /// Human-readable app name.
  final String label;

  /// Whether the platform marks this as a system app.
  final bool isSystem;

  /// Whether the user has frozen it.
  final bool frozen;

  /// Parses the map returned by the native method channel.
  factory FreezableApp.fromMap(Map<dynamic, dynamic> map) => FreezableApp(
        packageName: map['packageName'] as String,
        label: map['label'] as String,
        isSystem: (map['isSystem'] as bool?) ?? false,
        frozen: (map['frozen'] as bool?) ?? false,
      );

  /// Copy with a different frozen state.
  FreezableApp copyWith({bool? frozen}) => FreezableApp(
        packageName: packageName,
        label: label,
        isSystem: isSystem,
        frozen: frozen ?? this.frozen,
      );
}

/// Which enforcement tiers are currently available on the device.
class FreezeCapabilities {
  const FreezeCapabilities({
    required this.deviceAdminActive,
    required this.accessibilityEnabled,
    required this.canHideApps,
    required this.sdkInt,
  });

  /// True when Chest holds device-admin rights, enabling a hard freeze.
  final bool deviceAdminActive;

  /// True when the enforcement accessibility service is running.
  final bool accessibilityEnabled;

  /// True when the platform supports `setApplicationHidden` (API 21+).
  final bool canHideApps;

  /// Android API level.
  final int sdkInt;

  /// True when freezing is fully enforced at the OS level.
  bool get hardFreezeAvailable => deviceAdminActive && canHideApps;

  /// True when at least one enforcement mechanism is active.
  bool get anyEnforcement => hardFreezeAvailable || accessibilityEnabled;

  /// Parses the map returned by the native method channel.
  factory FreezeCapabilities.fromMap(Map<dynamic, dynamic> map) =>
      FreezeCapabilities(
        deviceAdminActive: (map['deviceAdminActive'] as bool?) ?? false,
        accessibilityEnabled: (map['accessibilityEnabled'] as bool?) ?? false,
        canHideApps: (map['canHideApps'] as bool?) ?? false,
        sdkInt: (map['sdkInt'] as int?) ?? 0,
      );

  /// Fallback used on platforms without the native bridge.
  static const FreezeCapabilities unsupported = FreezeCapabilities(
    deviceAdminActive: false,
    accessibilityEnabled: false,
    canHideApps: false,
    sdkInt: 0,
  );
}

/// Where the platform is holding the vault's wrapping key.
class HardwareSecurity {
  const HardwareSecurity({
    required this.keystoreAvailable,
    required this.strongBoxAvailable,
    required this.insideSecureHardware,
    this.error,
  });

  /// True when the Android Keystore is usable.
  final bool keystoreAvailable;

  /// True when the device has a discrete tamper-resistant security chip.
  final bool strongBoxAvailable;

  /// True when a probe key was bound to a TEE or secure element.
  final bool insideSecureHardware;

  /// Populated when the probe could not run.
  final String? error;

  /// A short label for the strongest available protection.
  String get grade {
    if (strongBoxAvailable && insideSecureHardware) return 'StrongBox';
    if (insideSecureHardware) return 'TEE';
    if (keystoreAvailable) return 'Keystore (software)';
    return 'Unavailable';
  }

  /// Parses the map returned by the native method channel.
  factory HardwareSecurity.fromMap(Map<dynamic, dynamic> map) => HardwareSecurity(
        keystoreAvailable: (map['keystoreAvailable'] as bool?) ?? false,
        strongBoxAvailable: (map['strongBoxAvailable'] as bool?) ?? false,
        insideSecureHardware: (map['insideSecureHardware'] as bool?) ?? false,
        error: map['error'] as String?,
      );

  /// Fallback used on platforms without the native bridge.
  static const HardwareSecurity unknown = HardwareSecurity(
    keystoreAvailable: false,
    strongBoxAvailable: false,
    insideSecureHardware: false,
  );
}

/// Outcome of a freeze or unfreeze request.
class FreezeResult {
  const FreezeResult({required this.applied, required this.method});

  /// True when the platform actually enforced the change.
  final bool applied;

  /// `device_admin`, `soft` or `protected`.
  final String method;

  /// True when the freeze is enforced by the OS rather than by Chest's service.
  bool get isHard => applied && method == 'device_admin';

  /// Parses the map returned by the native method channel.
  factory FreezeResult.fromMap(Map<dynamic, dynamic> map) => FreezeResult(
        applied: (map['applied'] as bool?) ?? false,
        method: (map['method'] as String?) ?? 'soft',
      );
}

/// Convenience view over raw bytes for UI display.
extension VaultEntryFormatting on VaultEntry {
  /// Human-readable size, for example `4.2 MB`.
  String get readableSize {
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = sizeBytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final rendered = value >= 10 || unit == 0
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '$rendered ${units[unit]}';
  }

  /// Plaintext bytes helper used by tests.
  static Uint8List asBytes(String s) => Uint8List.fromList(s.codeUnits);
}
