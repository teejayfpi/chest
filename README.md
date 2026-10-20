# Chest

A mobile vault that seals your files with layered encryption and lets you freeze
other apps on your phone.

Chest is built for one job: hold things that must not be read by anyone else.
That shapes every decision in the codebase, including the ones that make the app
less convenient.

---

## What it does

**Seals files.** Pick any file, or write a note in the app. Chest encrypts it
before it touches the disk and stores the result in its own private directory.

**Layers five encryption stages.** Your passphrase is stretched with Argon2id,
split into four independent subkeys with HKDF, then each file is encrypted with
AES-256-GCM and again with XChaCha20-Poly1305, with HMAC-SHA256 tags binding the
header and the envelope.

**Freezes other apps.** Chest can disable apps at the operating-system level so
they cannot launch, or hold them closed with a guard service where device-admin
rights are not available.

**Refuses to talk to the network.** The app requests no network permission at
all, so there is no code path, including one introduced by a dependency, that can
send your data anywhere.

---

## The five encryption layers

Each layer is independent. Breaking one does not weaken the next, and an attacker
has to defeat all five to read a single byte.

| # | Layer | What it does |
|---|-------|--------------|
| 1 | Argon2id | Turns the passphrase into a 256-bit root key. Memory-hard, so guessing is expensive in RAM as well as time. |
| 2 | HKDF-SHA256 | Splits the root key into four subkeys, each bound to a distinct domain label so a key can never be reused across purposes. |
| 3 | AES-256-GCM | Authenticated encryption of the padded plaintext. |
| 4 | XChaCha20-Poly1305 | A second, structurally different cipher over the AES output. The two have no shared weaknesses. |
| 5 | HMAC-SHA256 | Header and envelope tags covering every field, so tampering with the KDF parameters, salt, or lengths is detected rather than trusted. |

### Why two ciphers

A single modern cipher is already unbreakable in practice. Cascading AES-GCM with
XChaCha20-Poly1305 is defence against the case that actually worries a vault: an
implementation flaw or a future cryptanalytic advance in one algorithm. AES and
ChaCha rest on different mathematics, so a break in one leaves the other intact.

The cost is roughly double the encryption time for files, which on a phone means
milliseconds for anything a person would actually store.

### Why the header is authenticated

The container header records the KDF profile, the salt, and the lengths. If those
were not covered by a MAC, an attacker could rewrite the header to claim a weaker
KDF profile or a different salt and have the app cooperate. Chest computes an
HMAC over the header before deriving anything from it, and rejects the container
if the tag does not match.

### No downgrade path

The KDF profile is recorded in the header and validated on open. A container
written with the `paranoid` preset cannot be reopened under `standard`, so an
attacker who can edit the file cannot talk the app into weaker stretching.

---

## What Chest deliberately does not do

**No password recovery.** The key comes from your passphrase and nothing else.
There is no escrow, no recovery code, and no server. Lose the passphrase and the
data is gone — that is the property that makes the rest meaningful.

**No cloud backup.** Backup and device transfer are switched off in the manifest.
Sealed files leave the device only when you move them yourself.

**No network permission.** Not "we promise not to upload" — the app cannot open a
socket. This is verifiable in `android/app/src/main/AndroidManifest.xml`, where
`android.permission.INTERNET` is absent.

**Biometrics are not a key.** The fingerprint prompt is a convenience that saves
retyping. The vault key still comes from the passphrase. Biometric APIs can be
defeated on a rooted device, so treating a fingerprint as the protection would
weaken the vault rather than strengthen it.

---

## Freezing apps

Chest offers two tiers, and it tells you which one is active rather than
implying the stronger one is always available.

**Hard freeze — system-enforced.** With device-admin rights, Chest uses
`DevicePolicyManager.setApplicationHidden`. The frozen app is disabled by Android
itself: it cannot launch, it disappears from the launcher, and it stays disabled
after a reboot. This is the real thing.

**Soft freeze — guard service.** Without device-admin rights, an accessibility
service watches the foreground package name and sends you home when a frozen app
opens. The app is still installed and still launchable by other means, so this
tier is a speed bump, not a lock.

The service compares package names only. It is not declared to read window
content, so it cannot see what is on your screen.

---

## Security posture at a glance

- **Screenshot blocking.** `FLAG_SECURE` is set while the vault is unlocked, so
  the OS refuses screenshots and blanks the recents thumbnail.
- **Auto-lock.** Backgrounding the app locks the vault immediately. A three-minute
  idle timer locks it while the app is still in front.
- **Key wiping.** Derived keys are zeroed on lock and on dispose. The key buffer
  is owned by the session and wiped exactly once, so no copy outlives its use.
- **Explicit plaintext.** The vault list shows names only; file contents appear in
  a dialog you open and close deliberately, and are never written to disk.
- **Hardware key store probe.** The settings screen reports whether the platform
  offers StrongBox or a TEE, so you can see where key material could live rather
  than assuming the best case.

---

## Architecture

```
lib/
  crypto/          Cipher and key derivation — no UI, no platform calls
    cascade_cipher.dart      Container format, seal/open
    key_derivation.dart      Argon2id presets, HKDF expansion
    crypto_primitives.dart   Byte helpers, constant-time comparison
  core/
    vault_service.dart       Vault lifecycle, file storage, sessions
  models/          Plain data types shared across layers
  platform/        Bridges to Android and to the biometric prompt
  state/           ChestController: the single source of UI truth
  screens/         One screen per destination
  theme/           Palette and Material theme
  widgets/         Shared UI pieces
android/app/src/main/kotlin/com/chest/chest/
  MainActivity.kt                Method-channel bridge
  applock/ChestAppLockManager.kt Freeze enforcement
  applock/ChestAppLockService.kt Accessibility guard service
  applock/ChestAppLockStore.kt   Persisted frozen set
```

The dependency direction is one way: screens depend on state, state depends on
core and platform, core depends on crypto. Nothing in `crypto/` imports Flutter,
which is why it is testable without a device.

### Container format

```
[ magic 8 ][ version 1 ][ profile 1 ][ reserved 2 ]
[ salt 16 ][ nonceA 12 ][ nonceB 24 ][ plainLen 8 ]
[ headerMac 32 ]
[ aesCiphertext + tag ... ]
[ chachaCiphertext + tag ... ]
```

The plaintext is padded to a 512-byte boundary before the first cipher, with a
two-byte marker recording the true length. Padding to a fixed block means the
container length does not reveal the exact size of what you stored.

---

## Building

```bash
flutter pub get
flutter analyze          # expect: no issues
flutter test             # expect: 73 tests pass
flutter build apk --release
```

The Android layer needs no extra setup: the device-admin receiver and the
accessibility service are both declared in the manifest and bind only after the
user approves them through the system dialogs.

### Brand assets

Launcher icons and the logo are generated rather than hand-drawn:

```bash
python3 tool/generate_brand_assets.py
```

This writes every mipmap density, the adaptive-icon layers, and the store icon
from one set of coordinates, so the mark stays consistent everywhere it appears.

---

## Testing

The crypto layer carries the weight of the test suite, because a bug there is
silent and fatal:

- round-trip sealing across every KDF preset
- wrong passphrase and flipped ciphertext bits both rejected
- a tampered header, a downgraded KDF profile, and a swapped salt all rejected
- truncated and malformed containers rejected without crashing
- associated data actually binds a container to its vault
- the container never contains the plaintext, and never repeats itself
- key buffers are zeroed on dispose

`test/core/vault_service_test.dart` covers the storage layer on top: create,
unlock, add, list, search, delete, tamper detection, and use-after-dispose.

The widget tests drive the real screens against the real controller, replacing
only the platform method channels with fakes that answer exactly as Kotlin does.
`test/screens/unlock_screen_test.dart` builds an actual vault on a temporary
directory, so the unlock path is exercised end to end: a wrong passphrase is
refused, the right one opens the vault, and a successful biometric prompt still
does not unlock anything on its own.

---

## Limitations, stated plainly

- **Android only for freezing.** The freeze features are Android-specific. The
  vault itself is platform-independent Dart and runs anywhere Flutter does.
- **Soft freeze is weak.** Without device-admin rights the guard service can be
  bypassed by disabling the accessibility service. Chest says so in the UI.
- **No key wrapping in hardware.** The probe reports what the device offers; it
  does not yet wrap the root key in a hardware-backed key. That is the natural
  next step.
- **Recents thumbnails.** `FLAG_SECURE` covers the vault screen. The unlock screen
  is not covered, because there is nothing sensitive on it yet.

---

## Licence

See `LICENSE`.
