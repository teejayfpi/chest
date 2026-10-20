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

**Hides other apps.** Chest can remove apps from your launcher entirely, with
their data intact, and put them back the moment you unfreeze them. Hiding is
enforced by Android itself and survives a restart — and putting an app back needs
your passphrase, so it is not undone by whoever picks up the phone next.

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

## Hiding apps

Chest removes a frozen app from your launcher using
`DevicePolicyManager.setApplicationHidden`. The app cannot be started, its data
is left untouched, and it returns to the launcher the moment you unfreeze it. The
platform enforces this, so it holds across a reboot whether or not Chest is
running.

### Why Chest asks to be device owner

`setApplicationHidden` only works for a **device owner or profile owner**. Legacy
device-admin rights are not enough, and this is a hard platform rule rather than a
choice Chest makes:

> For legacy device admins, this API throws `SecurityException` if they target SDK
> level `N` or above.
> — [Android `DevicePolicyManager` reference](https://developer.android.com/reference/android/app/admin/DevicePolicyManager#setApplicationHidden(android.content.ComponentName,%20java.lang.String,%20boolean))

Chest targets a modern SDK, so a device-admin-only build could never hide
anything. Provisioning is a one-time step run from a computer:

```bash
adb shell dpm set-device-owner com.chest.chest/.applock.ChestDeviceAdminReceiver
```

The Freezer screen shows this command with a copy button whenever Chest is not yet
the device owner.

`dpm set-device-owner` only succeeds when the device has **no accounts and no
secondary users**, which in practice means a freshly factory-reset phone. It is a
development and testing tool, not a production deployment path. Real deployments
provision a device owner through an EMM at enrolment time.

### Being honest about what is enforced

Freezing has two tiers, and the UI always says which one is in force:

- **Hidden (device owner).** The app leaves the launcher and cannot be started.
- **Guard only (no device owner).** Chest cannot hide anything, so it falls back
  to an accessibility service that sends you home when the frozen app opens. The
  app is still in your launcher and still launchable by other means, so this is a
  speed bump rather than a lock.

Chest never marks an app frozen when the platform refused the hide. A switch that
claimed otherwise would tell you an app was hidden while it sat in your launcher.

The accessibility service compares package names only. It is not declared to read
window content, so it cannot see what is on your screen.

### Not getting locked out

Hiding apps you cannot restore is the real risk of a feature like this, so there
are three guards:

- **Protected packages.** Settings, SystemUI, launchers and the keyboard can never
  be hidden, because hiding them would leave you unable to undo a freeze.
- **Restore all.** The Freezer screen has a one-tap escape hatch that unhides
  every app Chest recorded, even ones no longer in the list.
- **Boot reconciliation.** A receiver re-applies the hidden set after a reboot or
  an app update, so a crash or a failed write cannot strand an app hidden.

Labels are cached at freeze time because a hidden package disappears from
`queryIntentActivities` — without the cached label, the very apps you froze would
vanish from the list you need in order to unfreeze them.

### Only you can release an app

Hiding an app is pointless if the next person to pick up the phone can simply tap
it back. Releasing a frozen app is the direction that exposes data, so it is the
one that is gated:

- **Two factors.** When the device has biometrics enrolled, releasing asks for a
  fingerprint **and** the vault passphrase. The passphrase is required even after
  the fingerprint passes. A fingerprint can be spoofed on a rooted device and can
  be taken from a sleeping owner, so it answers "is this the right person" but not
  "does this person know the secret". Only the passphrase proves knowledge.
- **No verifier on disk.** The passphrase is checked by re-deriving the root key
  from the vault's own salt and comparing it to the key held in memory, in
  constant time. Nothing extra is written to disk, so the gate adds no new
  offline attack target — the encrypted index already is one.
- **One-shot authorization.** A successful confirmation mints a single-use token,
  and the release call consumes it. Driving the controller directly without a
  token, replaying a spent token, or letting a confirmation survive an auto-lock
  all fail closed.
- **Throttling.** Wrong passphrases are counted and the gate refuses for a growing,
  capped delay. This is defence in depth over Argon2id, which is the real cost of
  guessing, not a replacement for it.
- **Freezing is not gated.** Freezing only adds protection, so it stays a single
  tap; gating it would make securing a dozen apps a dozen prompts while weakening
  nothing.

On a device with no biometrics enrolled the gate falls back to the passphrase
alone rather than becoming unusable. That is a real reduction in factors, and the
dialog says so.

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
- **Gated releases.** Unfreezing an app needs the passphrase (and a fingerprint
  when one is enrolled), so hiding an app is not undone by whoever picks up the
  phone next. See [Only you can release an app](#only-you-can-release-an-app).
- **Honest capability reporting.** Every screen that describes a protection checks
  whether it is actually active on this device. The app never claims a hide it did
  not perform or a guarantee the platform is not enforcing.

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
    protected_release_gate.dart  Two-factor confirmation for releases
android/app/src/main/kotlin/com/chest/chest/
  MainActivity.kt                Method-channel bridge
  applock/ChestAppLockManager.kt Hide/unhide via DevicePolicyManager
  applock/ChestAppLockService.kt Accessibility guard service
  applock/ChestAppLockStore.kt   Persisted hidden set and cached labels
  applock/ChestBootReceiver.kt   Re-applies hidden state after a reboot
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
flutter test             # expect: 94 tests pass
flutter build apk --release
```

The Android layer needs no extra setup to compile: the device-admin receiver, the
accessibility service and the boot receiver are all declared in the manifest and
bind only after the user approves them through the system dialogs.

Hiding apps additionally needs Chest provisioned as device owner. See
[Hiding apps](#hiding-apps) for the command.

### Building an APK in CI

`.github/workflows/build-apk.yml` builds the APK on GitHub's runners, so you do
not need Flutter installed to get an installable build.

It runs on every pull request, on every push to `main`, and on demand from the
**Actions → Build APK → Run workflow** button. `flutter analyze` and
`flutter test` run before the build, so no APK is produced from code that does not
compile or pass its tests.

Two artifacts come out of each run:

| Artifact | Contents |
| --- | --- |
| `chest-release-apk` | One fat APK with all three ABIs. Largest, works on anything. |
| `chest-release-apks-per-abi` | One APK per ABI. `arm64-v8a` is the one most phones need. |

Download them from the **Artifacts** section at the bottom of a run's summary
page. Artifacts are retained for 90 days by default and require a GitHub login to
download, even on a public repository.

Pushing a tag like `v1.0.0` additionally publishes the per-ABI APKs to **Releases**,
which is the link to hand out for a public build.

**The APKs are debug-signed by default, and debug-signed APKs are not fit for
distribution.** That is fine for sideloading onto your own phone, but anyone
holding the well-known AOSP debug key could sign an update Android would accept as
coming from you. To sign properly, generate a keystore and add four repository
secrets:

```bash
keytool -genkeypair -v -keystore chest-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias chest
base64 -w0 chest-release.jks   # paste the output into KEYSTORE_BASE64
```

| Secret | Value |
| --- | --- |
| `KEYSTORE_BASE64` | base64 of the `.jks` file |
| `KEYSTORE_PASSWORD` | the store password |
| `KEY_PASSWORD` | the key password |
| `KEY_ALIAS` | `chest` |

Add these under **Settings → Secrets and variables → Actions**. When they are
present the workflow signs with your key and says so in the log; when they are
absent it warns and falls back to the debug key rather than failing. Keep the
keystore itself out of the repository — losing it means you can never update an
installed app in place, and leaking it means someone else can.

Locally, real signing works the same way through `android/key.properties`, which
is gitignored:

```properties
storePassword=...
keyPassword=...
keyAlias=chest
storeFile=/absolute/path/to/chest-release.jks
```

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

`test/screens/release_gate_test.dart` covers the release gate the same way,
against a real unlocked vault, so the passphrase check really runs Argon2id rather
than a stand-in. It confirms that a successful fingerprint still demands the
passphrase, that a wrong passphrase releases nothing even when the fingerprint
passed, that tokens are single-use and do not survive a lock, that repeated
failures throttle the gate, and that freezing is never gated.

---

## Limitations, stated plainly

- **Android only for freezing.** The freeze features are Android-specific. The
  vault itself is platform-independent Dart and runs anywhere Flutter does.
- **Hiding needs device-owner provisioning.** Without it, Chest cannot hide an app
  from the launcher at all and falls back to the guard service, which can be
  bypassed by disabling the accessibility service. Chest says so in the UI rather
  than implying a hide happened.
- **Device owner is a powerful role.** Provisioning grants Chest the ability to
  wipe the device. Chest never calls it, but the capability comes with the role.
- **Provisioning needs a reset phone.** `dpm set-device-owner` requires no accounts
  and no secondary users, so it usually means a factory reset first.
- **Hidden system apps can be refused.** Some OEM builds reject hiding preinstalled
  packages; Chest reports the refusal instead of pretending it worked.
- **No key wrapping in hardware.** The probe reports what the device offers; it
  does not yet wrap the root key in a hardware-backed key. That is the natural
  next step.
- **The release gate protects Chest, not the whole phone.** It stops someone
  releasing an app *through Chest*. It cannot stop a determined attacker with an
  unlocked bootloader or root from calling `pm unhide` directly, from disabling
  Chest's accessibility service, or from re-provisioning the device owner. The
  gate raises the bar for the realistic case — someone handed your phone — and
  does not claim to defeat a rooted device. Nothing app-level can.
- **The gate's throttling is in memory.** It resets when the process restarts,
  because there is no safe place outside the vault to persist a counter without
  creating a new attack surface. Argon2id is the real cost of guessing; the delay
  is a speed bump on top.
- **Recents thumbnails.** `FLAG_SECURE` covers the vault screen. The unlock screen
  is not covered, because there is nothing sensitive on it yet.

---

## Licence

See `LICENSE`.
