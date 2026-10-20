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
    this.hidden = false,
  });

  /// Android package identifier.
  final String packageName;

  /// Human-readable app name.
  final String label;

  /// Whether the platform marks this as a system app.
  final bool isSystem;

  /// Whether the user has frozen it.
  final bool frozen;

  /// Whether the platform has actually removed it from the launcher.
  ///
  /// This is distinct from [frozen]: an app can be marked frozen while only the
  /// accessibility guard is enforcing it, in which case it is still visible in
  /// the launcher. Only a true hide takes it off the launcher entirely.
  final bool hidden;

  /// Parses the map returned by the native method channel.
  factory FreezableApp.fromMap(Map<dynamic, dynamic> map) => FreezableApp(
        packageName: map['packageName'] as String,
        label: map['label'] as String,
        isSystem: (map['isSystem'] as bool?) ?? false,
        frozen: (map['frozen'] as bool?) ?? false,
        hidden: (map['hidden'] as bool?) ?? false,
      );

  /// Copy with a different frozen state.
  FreezableApp copyWith({bool? frozen, bool? hidden}) => FreezableApp(
        packageName: packageName,
        label: label,
        isSystem: isSystem,
        frozen: frozen ?? this.frozen,
        hidden: hidden ?? this.hidden,
      );
}

/// Which enforcement tiers are currently available on the device.
class FreezeCapabilities {
  const FreezeCapabilities({
    required this.deviceOwnerActive,
    required this.profileOwnerActive,
    required this.deviceAdminActive,
    required this.accessibilityEnabled,
    this.notificationAccessEnabled = false,
    required this.hiddenCount,
    required this.sdkInt,
    this.packageName = 'com.chest.chest',
  });

  /// True when Chest is provisioned as device owner.
  ///
  /// This is the only state in which an app can actually be hidden from the
  /// launcher. Legacy device-admin rights are deliberately not enough: the
  /// platform rejects `setApplicationHidden` from a legacy admin on any app
  /// targeting API 24 or above.
  final bool deviceOwnerActive;

  /// True when Chest is a profile owner. Also sufficient to hide apps.
  ///
  /// Note the scope limit: a profile owner manages a *work profile* and can only
  /// hide packages inside it. It cannot hide the personal apps the user actually
  /// sees in their main launcher. See [canHideApps].
  final bool profileOwnerActive;

  /// True when Chest holds legacy device-admin rights.
  final bool deviceAdminActive;

  /// True when the enforcement accessibility service is running.
  final bool accessibilityEnabled;

  /// True when the user has granted Chest notification access.
  ///
  /// A separate grant from the accessibility one, because dismissing another
  /// app's notification requires a `NotificationListenerService`. Without it a
  /// frozen messenger can still show message text in the shade.
  final bool notificationAccessEnabled;

  /// Number of apps Chest currently has hidden.
  final int hiddenCount;

  /// Android API level.
  final int sdkInt;

  /// Chest's own package name, used to build the provisioning command.
  final String packageName;

  /// True when the platform will accept a hide request.
  ///
  /// This is deliberately device owner only, *not* device owner or profile
  /// owner. Both satisfy the platform's permission check, but a profile owner
  /// governs a separate work profile: it can hide work apps and cannot touch the
  /// personal apps in the user's main launcher. Reporting "launcher hiding
  /// active" for a profile owner would promise a hide on exactly the apps it
  /// cannot perform it on, so a profile owner is treated as the soft tier.
  bool get canHideApps => deviceOwnerActive;

  /// True when Chest is a profile owner but not the device owner.
  ///
  /// Surfaced so the UI can explain the narrower scope instead of implying the
  /// freeze applies to the whole phone.
  bool get profileOwnerOnly => profileOwnerActive && !deviceOwnerActive;

  /// Parses the map returned by the native method channel.
  factory FreezeCapabilities.fromMap(Map<dynamic, dynamic> map) => FreezeCapabilities(
        deviceOwnerActive: (map['deviceOwnerActive'] as bool?) ?? false,
        profileOwnerActive: (map['profileOwnerActive'] as bool?) ?? false,
        deviceAdminActive: (map['deviceAdminActive'] as bool?) ?? false,
        accessibilityEnabled: (map['accessibilityEnabled'] as bool?) ?? false,
        notificationAccessEnabled: (map['notificationAccessEnabled'] as bool?) ?? false,
        hiddenCount: (map['hiddenCount'] as int?) ?? 0,
        sdkInt: (map['sdkInt'] as int?) ?? 0,
        packageName: (map['packageName'] as String?) ?? 'com.chest.chest',
      );

  /// Fallback used on platforms without the native bridge.
  static const FreezeCapabilities unsupported = FreezeCapabilities(
    deviceOwnerActive: false,
    profileOwnerActive: false,
    deviceAdminActive: false,
    accessibilityEnabled: false,
    hiddenCount: 0,
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
  const FreezeResult({
    required this.applied,
    required this.method,
    this.restored = 0,
    this.failed = 0,
  });

  /// True when the platform actually enforced the change.
  final bool applied;

  /// How the change was enforced.
  ///
  /// - `device_owner` — hidden from the launcher by the platform.
  /// - `accessibility` — blocked on open by the app guard, still in the launcher.
  /// - `none` — nothing could enforce it; no freeze was recorded.
  /// - `protected` — refused because the package must stay reachable.
  final String method;

  /// Apps restored by an [AppLockBridge.unhideAll] call.
  final int restored;

  /// Apps that could not be restored by an [AppLockBridge.unhideAll] call.
  final int failed;

  /// True when the freeze removed the app from the launcher.
  ///
  /// Only a device-owner hide achieves this; the accessibility tier leaves the
  /// app in the launcher and blocks it on open instead.
  bool get isHard => applied && method == 'device_owner';

  /// True when the freeze is enforced by the app guard rather than the platform.
  ///
  /// Real enforcement — the app is blocked the moment it opens — but the icon
  /// remains visible, so the UI must not describe it as hidden.
  bool get isGuarded => applied && method == 'accessibility';

  /// True when no mechanism could enforce the freeze.
  bool get isUnenforced => !applied && method == 'none';

  /// Parses the map returned by the native method channel.
  factory FreezeResult.fromMap(Map<dynamic, dynamic> map) => FreezeResult(
        applied: (map['applied'] as bool?) ?? false,
        method: (map['method'] as String?) ?? 'soft',
        restored: (map['restored'] as int?) ?? 0,
        failed: (map['failed'] as int?) ?? 0,
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
