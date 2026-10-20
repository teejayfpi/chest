import 'dart:io';

import 'package:chest/core/vault_service.dart';
import 'package:chest/crypto/key_derivation.dart';
import 'package:chest/models/vault_models.dart';
import 'package:chest/platform/biometric_service.dart';
import 'package:chest/screens/freezer_screen.dart';
import 'package:chest/state/chest_controller.dart';
import 'package:chest/theme/chest_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart' show BiometricType;
import 'package:provider/provider.dart';

import 'freezer_screen_test.dart' show FakeAppLockChannel;

/// A biometric service whose verdict the test chooses, without touching the
/// plugin. [verdict] is re-read on every call so a test can change the outcome
/// between attempts.
class ScriptedBiometrics implements BiometricService {
  ScriptedBiometrics({this.available = true});

  final bool available;
  BiometricOutcome verdict = BiometricOutcome.success;

  int prompts = 0;

  @override
  Future<bool> isSupported() async => available;

  @override
  Future<bool> canAuthenticate() async => available;

  @override
  Future<List<BiometricType>> availableTypes() async => const [];

  @override
  Future<BiometricOutcome> authenticate({
    required String reason,
    bool allowPasscodeFallback = true,
  }) async {
    prompts++;
    return available ? verdict : BiometricOutcome.unavailable;
  }
}

/// A real, unlocked vault plus a scripted biometric prompt.
class GateHarness {
  GateHarness._(this.directory, this.controller, this.channel, this.biometrics);

  final Directory directory;
  final ChestController controller;
  final FakeAppLockChannel channel;
  final ScriptedBiometrics biometrics;

  /// Guards against disposing twice, which happens when a test swaps the
  /// harness mid-body and the tear-down then runs on both.
  bool _disposed = false;

  static const String passphrase = 'the-correct-horse-battery';

  /// Builds a vault on disk and leaves it **unlocked**, because the gate verifies
  /// against the live session key.
  ///
  /// Must run outside a `testWidgets` body: Argon2id is real CPU work the
  /// widget-test fake-async zone cannot drive.
  static Future<GateHarness> unlocked({
    bool biometricsAvailable = true,
    Map<String, Object?>? capabilities,
  }) async {
    final directory = await Directory.systemTemp.createTemp('chest_gate_test_');
    final channel = FakeAppLockChannel(capabilities: capabilities)..install();
    final biometrics = ScriptedBiometrics(available: biometricsAvailable);

    final controller = ChestController(
      vaultService: VaultService(directory: directory),
      biometrics: biometrics,
    )..setProfile(KdfProfile.standard);

    final created = await controller.createVault(passphrase);
    expect(created, isTrue, reason: 'the fixture vault should be created');

    // createVault leaves the session open, which is what the gate needs.
    return GateHarness._(directory, controller, channel, biometrics);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    controller.dispose();
    channel.remove();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

/// A frozen app fixture, as the native list would report it.
const FreezableApp chatApp = FreezableApp(
  packageName: 'com.example.chat',
  label: 'Chat',
  isSystem: false,
  frozen: true,
  hidden: true,
);

/// Pumps the freezer against a real controller on a tall viewport.
Future<void> pumpGateFreezer(WidgetTester tester, GateHarness harness) async {
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ChangeNotifierProvider<ChestController>.value(
      value: harness.controller,
      child: MaterialApp(theme: ChestTheme.dark(), home: const FreezerScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

/// Opens the release gate for the frozen Chat entry.
///
/// The biometric prompt resolves asynchronously, so this pumps until the gate
/// has settled rather than assuming a fixed number of frames.
Future<void> openGate(WidgetTester tester) async {
  // Chat is the only frozen entry, so it owns the second switch after Photos.
  await tester.tap(find.byType(Switch).at(1));
  await tester.pumpAndSettle();
}

/// Enters [passphrase] and taps Release, driving the real Argon2id derivation.
///
/// Verification runs as genuine CPU work, which the widget test's fake-async
/// zone cannot advance, so the tap is issued inside [WidgetTester.runAsync] and
/// the test polls the controller until the derivation finishes.
Future<void> submitPassphrase(
  WidgetTester tester,
  ChestController controller,
  String passphrase,
) async {
  await tester.enterText(find.byType(TextField).last, passphrase);
  await tester.pump();
  await tester.runAsync(() async {
    await tester.tap(find.text('Release'));
    for (var i = 0; i < 400 && controller.authorizingRelease; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('release gate', () {
    late GateHarness harness;

    setUp(() async {
      harness = await GateHarness.unlocked(
        capabilities: FakeAppLockChannel.capabilitiesFor(deviceOwnerActive: true),
      );
    });

    tearDown(() async {
      await harness.dispose();
    });

    testWidgets('the gate asks for the passphrase even after biometrics pass',
        (tester) async {
      await pumpGateFreezer(tester, harness);
      await openGate(tester);

      // The biometric prompt ran and passed...
      expect(harness.biometrics.prompts, greaterThan(0));
      expect(find.text('PASSED'), findsOneWidget);
      // ...and the passphrase step is still on screen, because the fingerprint
      // alone must not be enough.
      expect(find.text('Vault passphrase'), findsOneWidget);
      expect(
        find.textContaining('fingerprint is not enough on its own'),
        findsOneWidget,
      );
    });

    testWidgets('the right passphrase releases the app', (tester) async {
      await pumpGateFreezer(tester, harness);
      await openGate(tester);

      await submitPassphrase(tester, harness.controller, GateHarness.passphrase);

      expect(harness.channel.unfreezeCalls, ['com.example.chat']);
      expect(find.text('Chat is back in the launcher.'), findsOneWidget);
    });

    testWidgets('a wrong passphrase releases nothing', (tester) async {
      await pumpGateFreezer(tester, harness);
      await openGate(tester);

      await submitPassphrase(tester, harness.controller, 'not-the-passphrase');

      expect(find.textContaining('not your passphrase'), findsOneWidget);
      expect(harness.channel.unfreezeCalls, isEmpty);
      // The vault is untouched and the app is still frozen.
      expect(harness.controller.isUnlocked, isTrue);
    });

    testWidgets('a failed biometric prompt refuses before the passphrase is even tried',
        (tester) async {
      harness.biometrics.verdict = BiometricOutcome.failed;
      await pumpGateFreezer(tester, harness);
      await openGate(tester);

      await submitPassphrase(tester, harness.controller, GateHarness.passphrase);

      // Correct passphrase, but the biometric factor did not pass, so the
      // controller refuses. This is the whole point of requiring both.
      expect(harness.channel.unfreezeCalls, isEmpty);
      expect(find.textContaining('not your passphrase'), findsOneWidget);
    });

    testWidgets('an unlocked but disposed session refuses to authorise',
        (tester) async {
      // A stale dialog must not be able to authorise anything once the vault has
      // been locked underneath it.
      harness.controller.lock();

      final result = await harness.controller.authorizeRelease(GateHarness.passphrase);

      expect(result.authorized, isFalse);
      expect(result.decision, ReleaseDecision.vaultLocked);
    });

    testWidgets('repeated wrong passphrases throttle the gate', (tester) async {
      await pumpGateFreezer(tester, harness);
      await openGate(tester);

      for (var i = 0; i < ChestController.releaseAttemptLimit; i++) {
        // The biometric prompt already ran and passed when the gate opened. Each
        // failed attempt spends that factor, so every round past the first has to
        // re-run it before the passphrase is even considered.
        if (i > 0) {
          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
        }
        await submitPassphrase(tester, harness.controller, 'wrong-$i');
      }

      expect(harness.controller.releaseBlocked, isTrue);

      // Even the correct passphrase is refused while the gate is throttled.
      final result = await harness.controller.authorizeRelease(GateHarness.passphrase);
      expect(result.decision, ReleaseDecision.throttled);
      expect(harness.channel.unfreezeCalls, isEmpty);
    });
  });

  group('release gate without biometrics', () {
    late GateHarness harness;

    setUp(() async {
      // Built in setUp, not in the test body: Argon2id is real CPU work that the
      // widget test's fake-async zone cannot drive.
      harness = await GateHarness.unlocked(
        biometricsAvailable: false,
        capabilities: FakeAppLockChannel.capabilitiesFor(deviceOwnerActive: true),
      );
    });

    tearDown(() async {
      await harness.dispose();
    });

    testWidgets('the passphrase alone still releases an app', (tester) async {
      await pumpGateFreezer(tester, harness);
      await openGate(tester);

      // No biometric step is shown, so the gate is passphrase-only rather than
      // becoming unusable on a device with nothing enrolled.
      expect(find.text('Biometric check'), findsNothing);
      expect(find.textContaining('No biometrics are enrolled'), findsOneWidget);

      await submitPassphrase(tester, harness.controller, GateHarness.passphrase);

      expect(harness.channel.unfreezeCalls, ['com.example.chat']);
    });
  });

  group('release authorization tokens', () {
    late GateHarness harness;

    setUp(() async {
      harness = await GateHarness.unlocked();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('a release without a token is refused', () async {
      final result = await harness.controller.releaseApp(chatApp, authorization: null);

      expect(result, isNull);
      expect(harness.channel.unfreezeCalls, isEmpty);
    });

    test('a forged token is refused', () async {
      final result = await harness.controller.releaseApp(
        chatApp,
        authorization: 'not-a-real-token',
      );

      expect(result, isNull);
      expect(harness.channel.unfreezeCalls, isEmpty);
    });

    test('a token is single-use, so one confirmation cannot release two apps',
        () async {
      await harness.controller.confirmReleaseWithBiometrics();
      final auth = await harness.controller.authorizeRelease(GateHarness.passphrase);
      expect(auth.authorized, isTrue);

      final token = harness.controller.pendingReleaseAuthorization;
      final first = await harness.controller.releaseApp(chatApp, authorization: token);
      expect(first, isNotNull);

      // Replaying the same token must fail: the authorization was spent.
      final second = await harness.controller.releaseApp(chatApp, authorization: token);
      expect(second, isNull);
      expect(harness.channel.unfreezeCalls.length, 1);
    });

    test('locking discards any outstanding authorization', () async {
      await harness.controller.confirmReleaseWithBiometrics();
      final auth = await harness.controller.authorizeRelease(GateHarness.passphrase);
      expect(auth.authorized, isTrue);

      harness.controller.lock();

      // The token minted before the lock must not survive it.
      final released = await harness.controller.releaseApp(chatApp, authorization: 'ignored');
      expect(released, isNull);
      expect(harness.controller.pendingReleaseAuthorization, isNull);
    });
  });

  group('freezing is never gated', () {
    test('freezeApp does not need authorization', () async {
      // Freezing only adds protection, so it must work without a passphrase.
      final directory = await Directory.systemTemp.createTemp('chest_freeze_test_');
      final channel = FakeAppLockChannel(
        capabilities: FakeAppLockChannel.capabilitiesFor(deviceOwnerActive: true),
      )..install();
      final controller = ChestController(vaultService: VaultService(directory: directory))
        ..setProfile(KdfProfile.standard);

      try {
        await controller.createVault('freeze-passphrase-here');

        const app = FreezableApp(
          packageName: 'com.example.photos',
          label: 'Photos',
          isSystem: false,
          frozen: false,
        );
        final result = await controller.freezeApp(app);

        expect(result.applied, isTrue);
        expect(channel.freezeCalls, ['com.example.photos']);
      } finally {
        controller.dispose();
        channel.remove();
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    });
  });

  group('lockout schedule', () {
    test('grows exponentially and stays capped', () {
      expect(ChestController.lockoutFor(0), Duration.zero);
      expect(ChestController.lockoutFor(1), const Duration(seconds: 2));
      expect(ChestController.lockoutFor(2), const Duration(seconds: 4));
      expect(ChestController.lockoutFor(3), const Duration(seconds: 8));
      // Capped, so a long-lived process cannot overflow into an absurd wait.
      expect(
        ChestController.lockoutFor(40),
        lessThanOrEqualTo(const Duration(seconds: 900)),
      );
    });
  });
}
