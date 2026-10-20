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
- `android/app/src/main/kotlin/com/chest/chest/` — `applock/` holds the device
  admin receiver, the accessibility service and the freeze store/manager.

## Commands

```bash
flutter analyze            # must be clean
flutter test               # 73 tests
flutter build apk --release
```

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
  reuse it.
- **Tall viewports are required** for the form screens, which extend past the
  default 800x600 test surface.
- The freeze UI has two honest tiers: device admin is a real system-enforced
  freeze, the accessibility service is a weaker "send home" guard. Do not present
  them as equivalent.
