# AGENTS.md

Repository notes for agents working on Chest.

## What this is

Chest is a Flutter (Dart UI) + Kotlin (Android native) encrypted vault that also
freezes apps at the OS level. There is no iOS implementation of the freeze tiers;
the Dart layer degrades gracefully off-Android.

## Layout

- `lib/crypto/` — the encryption cascade. `cascade_cipher.dart` seals containers,
  `key_derivation.dart` holds the Argon2id presets, `crypto_primitives.dart` has
  the exception types and byte helpers.
- `lib/core/vault_service.dart` — on-disk layout: `vault.json` (descriptor, holds
  the KDF salt), `index.chest` (encrypted index), `blobs/<id>.chest` (one sealed
  container per file).
- `lib/platform/` — MethodChannel bridges. `app_lock_bridge.dart` talks to the
  Kotlin freezer; `biometric_service.dart` wraps `local_auth`.
- `lib/state/chest_controller.dart` — single source of truth. Owns the auto-lock
  timer and every call into crypto/platform. Widgets never touch keys or channels.
- `android/app/src/main/kotlin/com/chest/chest/` — `applock/` holds the
  device-admin receiver, the accessibility service, the hide store/manager and
  the boot receiver.

## Commands

```bash
flutter analyze            # must be clean
flutter test               # 80 tests
flutter build apk --release
```

## Hiding apps is device-owner only

`DevicePolicyManager.setApplicationHidden` is restricted to a **device owner or
profile owner**. A legacy device admin calling it gets `SecurityException` on any
app targeting API 24+, which Chest does. This is the single most important thing
to understand before touching `ChestAppLockManager`: device-admin rights do not
let Chest hide anything, and code that assumes otherwise is wrong.

Provisioning is `adb shell dpm set-device-owner
com.chest.chest/.applock.ChestDeviceAdminReceiver`, and it needs a device with no
accounts and no secondary users.

Three invariants keep the feature from stranding a user:

1. **Labels are cached at freeze time.** A hidden package disappears from
   `queryIntentActivities`, so without the cached label it would vanish from the
   freeze list and could never be unhidden.
2. **Nothing is recorded unless the platform confirmed the hide.** `freeze()`
   only writes to the store when `setApplicationHidden` returned true, so the UI
   cannot claim a freeze that is not in force.
3. **`unhideAll` is the escape hatch.** It iterates the local record because no
   API enumerates hidden packages.

## Gotchas

- **Error mapping branches on type, not text.** Every `ChestCryptoException`
  subclass stringifies to the *base* class name, so `toString().contains(...)`
  silently never matches. Use `is ChestError(e, 'code')` or an `is` check.
- **Argon2id is real CPU work and cannot run under `testWidgets` fake-async.**
  Build vaults in `setUp` (outside the widget-test body) and use
  `tester.runAsync` plus polling on `controller.busy` to await an unlock. Use
  `KdfProfile.standard` in tests; `hardened` (the app default, 128 MiB) is slow
  enough to blow test timeouts.
- **Unmocked MethodChannels never reply in `flutter_test`.** Any code that
  `await`s a channel will hang. `test/screens/freezer_screen_test.dart` exposes
  `FakeAppLockChannel`, which mocks both the app-lock and security channels —
  reuse it. Its `freeze` handler mirrors the native rule that only a device owner
  gets `applied: true`, so tests exercise the honest-refusal path.
- **Tall viewports are required** for the form screens, which extend past the
  default 800x600 test surface.
- The Kotlin is not covered by `flutter test`. It is only checked by
  `flutter build apk`, which needs `JAVA_HOME` set (source `/workspace/env.sh`).
  A JDK can vanish from this image; reinstall with
  `sudo apt-get install -y openjdk-21-jdk-headless`.
