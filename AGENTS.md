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
  Kotlin freezer; `biometric_service.dart` wraps `local_auth`;
  `chest_files_bridge.dart` drives the native picker, reader, original-remover
  and share chooser.
- `lib/core/chest_author.dart` — the builder credit shown in Settings.
- `lib/state/chest_controller.dart` — single source of truth. Owns the auto-lock
  timer and every call into crypto/platform. Widgets never touch keys or channels.
- `android/app/src/main/kotlin/com/chest/chest/` — `applock/` holds the
  device-admin receiver, the accessibility guard service, the notification guard,
  the frozen-set registry/store/manager and the boot receiver. `files/` holds
  `ChestFilePicker` (SAF) and `ChestFileSealer`.
- `assets/branding/` — generated logo/mark/splash PNGs, produced by
  `tool/generate_brand_assets.py`. The logo is displayed in the Settings credit
  card; `test/widget/brand_assets_test.dart` asserts they are bundled, because
  `Image.asset` fails at runtime rather than at build time.

`MainActivity` extends `FlutterFragmentActivity`, not `FlutterActivity`, because
the file picker needs `registerForActivityResult` from `ComponentActivity`.

## Commands

```bash
flutter analyze            # must be clean
flutter test               # 112 tests
flutter build apk --release
```

## CI

`.github/workflows/build-apk.yml` runs analyze, test, then a fat APK build and a
`--split-per-abi` build, uploading both as artifacts. Verify workflow edits with
`actionlint`, and keep the pinned `FLUTTER_VERSION` in the workflow in step with
the version the project is developed against — a mismatch shows up as
widget-test failures that do not reproduce locally.

The release APK is debug-signed unless `android/key.properties` exists. CI writes
that file from repository secrets when `KEYSTORE_BASE64` is set and skips it
otherwise, so forks build without any signing configuration.

## Freezing has two tiers, and the phone-only one is primary

Freezing must work on a phone with nothing but the app installed. Device-owner
provisioning needs a computer and usually a factory reset, so it is an *optional
upgrade*, never a prerequisite. The UI leads with the on-device path.

**Tier 1 — the app guard (any phone).** `ChestAppLockService`, an accessibility
service the user enables in Settings:

- Covers a frozen app with an opaque `TYPE_ACCESSIBILITY_OVERLAY` the instant it
  reaches the foreground, then sends the user home. The overlay is load-bearing:
  the home transition takes a few frames, and without it the frozen app is briefly
  readable.
- `ChestNotificationGuard`, a `NotificationListenerService`, cancels notifications
  from frozen apps. It must be a separate service — an accessibility service
  genuinely cannot cancel another app's notification, because `NotificationManager.cancel`
  only affects the caller's own.

**Tier 2 — launcher hiding (device owner).**
`DevicePolicyManager.setApplicationHidden` is restricted to a **device owner or
profile owner**. A legacy device admin calling it gets `SecurityException` on any
app targeting API 24+, which Chest does. When Chest is the device owner, freezing
removes the icon from the launcher entirely.

A **profile owner is deliberately not treated as able to hide apps**:
`canHideApps` is `deviceOwnerActive` only. A profile owner governs a separate work
profile, so it can hide work apps and cannot touch the personal apps in the main
launcher — counting it would promise a hide on exactly the apps it cannot perform
one on.

Provisioning is `adb shell dpm set-device-owner
com.chest.chest/.applock.ChestDeviceAdminReceiver`, and it needs a device with no
accounts and no secondary users.

Invariants to preserve if you touch this:

1. **Never record a freeze nothing can enforce.** `freeze()` records the package
   only when the platform hid it or the guard is running to block it. A switch
   claiming otherwise would tell the user an app is contained while it opens
   normally. `unhideAll` is the escape hatch, and it clears the store even when a
   platform unhide failed, because clearing is what releases the guard.
2. **The shield must lower itself.** It is added over a frozen app; nothing else
   removes it, so without the timed lower (and the lower on leaving a frozen
   package) it would sit permanently over the home screen and lock the user out of
   their own phone. This was a real bug in the first draft.
3. **The frozen set is shared in-process, not broadcast.** `FrozenSetRegistry` is
   read by both the manager and the service. A broadcast would be missed entirely:
   the guard is usually idle when the user taps freeze, and no receiver is
   registered. Do not reintroduce one.
4. **Only `TYPE_WINDOW_STATE_CHANGED` is handled.** `TYPE_WINDOWS_CHANGED` needs
   `canRetrieveWindowContent="true"`, and Chest keeps that `false` so the service
   is technically incapable of reading screen text. Do not flip it on.
5. **Labels are cached at freeze time.** A hidden package disappears from
   `queryIntentActivities`, so without the cached label it would vanish from the
   freeze list and could never be unhidden.

## Releasing an app is gated

Freezing and releasing are deliberately asymmetric. `freezeApp` is ungated;
`releaseApp` and `releaseAll` require a one-shot authorization token that only
`authorizeRelease` mints, and that only after the biometric factor (when available)
*and* the passphrase both pass.

Invariants to preserve if you touch this:

1. **The passphrase is verified against the live session key**, not a stored
   verifier (`VaultSession.verifyPassphrase`). Writing a verifier to disk would add
   a new offline target for no gain.
2. **A biometric result is never sufficient on its own.** `_biometricSatisfiedThisAttempt`
   is consumed on *every* attempt, pass or fail, so a stale "passed" cannot be
   reused. Tests in `release_gate_test.dart` assert this.
3. **Authorization is single-use and dies with the session.** `lock()` clears the
   token, and `_consumeAuthorization` always spends it, so one confirmation cannot
   release two apps and a dialog cannot outlive the vault it was checked against.
4. **A refused release returns `null` and touches no channel.** `releaseApp` and
   `releaseAll` check the token *before* calling into the bridge, so an
   unauthorized caller cannot unfreeze anything even by driving the controller
   directly from a widget.

## Gotchas

- **Error mapping branches on type, not text.** Every `ChestCryptoException`
  subclass stringifies to the *base* class name, so `toString().contains(...)`
  silently never matches. Use `is ChestError(e, 'code')` or an `is` check.
- **Argon2id is real CPU work and cannot run under `testWidgets` fake-async.**
  Build vaults in `setUp` (outside the widget-test body) and use
  `tester.runAsync` plus polling on `controller.busy` (for unlock) or
  `controller.authorizingRelease` (for the release gate) to await the derivation.
  Use `KdfProfile.standard` in tests; `hardened` (the app default, 128 MiB) is
  slow enough to blow test timeouts.
- **Unmocked MethodChannels never reply in `flutter_test`.** Any code that
  `await`s a channel will hang. `test/screens/freezer_screen_test.dart` exposes
  `FakeAppLockChannel`, which mocks both the app-lock and security channels —
  reuse it. Its `freeze` handler mirrors the native rule that a freeze is applied
  only when the platform hid the app or the guard is running, so tests exercise the
  honest-refusal path.
- **Tall viewports are required** for the form screens, which extend past the
  default 800x600 test surface.
- The Kotlin is not covered by `flutter test`. It is only checked by
  `flutter build apk`, which needs `JAVA_HOME` set (source `/workspace/env.sh`).
  A JDK can vanish from this image; reinstall with
  `sudo apt-get install -y openjdk-21-jdk-headless`.
- **No `file_picker` plugin, on purpose.** The plugin copies every picked file
  into the app cache as **plaintext** before Dart ever sees it, which defeats a
  vault, and its `AndroidOptions` default to read-only, so the original could not
  be deleted. `ChestFilePicker` drives the Storage Access Framework directly with
  `readWrite` and streams bytes straight to the vault. Do not reintroduce it.
- **Deleting the original needs a write grant.** `deleteSource` returns
  `removed: false` when the provider refuses (for example a `content://` image
  the picker granted read-only). Treat that as "sealed but still visible" and
  tell the user; do not report it as hidden, and do not roll the entry back —
  the bytes are safe either way.
- **Sealing order is load-bearing.** Always read and seal before deleting the
  original, so a failure can lose nothing. `hide_files_test.dart` asserts the
  call order on the channel, not just the end state.
- **No INTERNET permission, ever.** WhatsApp contact goes through the native
  bridge to `wa.me` rather than a URL launcher, so the app keeps its offline
  posture. `aapt2 dump permissions` on the release APK is the check.
