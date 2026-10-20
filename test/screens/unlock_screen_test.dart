import 'dart:io';

import 'package:chest/core/vault_service.dart';
import 'package:chest/crypto/key_derivation.dart';
import 'package:chest/platform/biometric_service.dart';
import 'package:chest/screens/unlock_screen.dart';
import 'package:chest/state/chest_controller.dart';
import 'package:chest/theme/chest_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart' show BiometricType;
import 'package:provider/provider.dart';

import 'freezer_screen_test.dart' show FakeAppLockChannel;

/// A biometric service that never prompts, so tests do not touch the plugin.
class SilentBiometrics implements BiometricService {
  SilentBiometrics({this.available = false});

  final bool available;

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
  }) async =>
      available ? BiometricOutcome.success : BiometricOutcome.unavailable;
}

/// A real vault on a temporary directory, driven through the real controller.
class UnlockHarness {
  UnlockHarness._(this.directory, this.controller, this.channel);

  final Directory directory;
  final ChestController controller;
  final FakeAppLockChannel channel;

  static const String passphrase = 'a-perfectly-good-passphrase';

  /// Builds a vault on disk with [passphrase], then leaves it locked.
  ///
  /// Must be called outside a `testWidgets` body: the Argon2id layer runs as
  /// real CPU work, which the fake-async zone inside a widget test cannot drive.
  static Future<UnlockHarness> create({bool biometricsAvailable = false}) async {
    final directory = await Directory.systemTemp.createTemp('chest_unlock_test_');
    final channel = FakeAppLockChannel()..install();

    final controller = ChestController(
      vaultService: VaultService(directory: directory),
      biometrics: SilentBiometrics(available: biometricsAvailable),
    )
      // The lightest preset keeps pure-Dart Argon2id from dominating the run.
      // The KDF itself is covered by the crypto tests; here it only has to
      // succeed, and the vault must be reopenable by the screen under test.
      ..setProfile(KdfProfile.standard);

    final created = await controller.createVault(passphrase);
    expect(created, isTrue, reason: 'the fixture vault should be created');
    controller.lock();

    // initialise() is what a cold start runs: it re-resolves the route, probes
    // the freeze tiers and reads the hardware-security grade.
    await controller.initialise();

    return UnlockHarness._(directory, controller, channel);
  }

  Future<void> dispose() async {
    controller.dispose();
    channel.remove();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

/// Taps [finder] and waits for the real CPU-bound unlock to finish.
///
/// Argon2id runs outside the fake-async zone, so the tap is issued inside
/// [WidgetTester.runAsync] and the test polls the controller until it is no
/// longer busy, rather than pumping on a timer that the work cannot advance.
Future<void> tapAndAwait(
  WidgetTester tester,
  Finder finder,
  ChestController controller,
) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    for (var i = 0; i < 400 && controller.busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// Pumps the unlock screen on a tall viewport.
Future<void> pumpUnlock(WidgetTester tester, UnlockHarness harness) async {
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ChangeNotifierProvider<ChestController>.value(
      value: harness.controller,
      child: MaterialApp(theme: ChestTheme.dark(), home: const UnlockScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('unlock screen', () {
    late UnlockHarness harness;

    setUp(() async {
      harness = await UnlockHarness.create();
    });

    tearDown(() async {
      await harness.dispose();
    });

    testWidgets('asks for the passphrase', (tester) async {
      await pumpUnlock(tester, harness);

      expect(find.text('CHEST'), findsOneWidget);
      expect(find.text('SEALED BY DESIGN'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Open the chest'), findsOneWidget);
    });

    testWidgets('reports where the key material is held', (tester) async {
      await pumpUnlock(tester, harness);

      // The fake security channel reports a TEE, so the grade is not the
      // "Unavailable" fallback.
      expect(find.textContaining('Key material held in: TEE'), findsOneWidget);
    });

    testWidgets('obscures the passphrase by default', (tester) async {
      await pumpUnlock(tester, harness);

      expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isTrue);
    });

    testWidgets('the visibility toggle reveals the passphrase', (tester) async {
      await pumpUnlock(tester, harness);

      await tester.tap(find.byTooltip('Show'));
      await tester.pump();

      expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isFalse);
    });

    testWidgets('an empty passphrase is refused before any key work', (tester) async {
      await pumpUnlock(tester, harness);

      await tapAndAwait(tester, find.text('Open the chest'), harness.controller);

      expect(find.text('Enter your passphrase.'), findsOneWidget);
      expect(harness.controller.route, ChestRoute.unlock);
      expect(harness.controller.isUnlocked, isFalse);
    });

    testWidgets('a wrong passphrase is refused and the vault stays shut', (tester) async {
      await pumpUnlock(tester, harness);

      await tester.enterText(find.byType(TextField), 'definitely-not-the-passphrase');
      await tapAndAwait(tester, find.text('Open the chest'), harness.controller);

      expect(find.textContaining('did not open the vault'), findsOneWidget);
      expect(harness.controller.route, ChestRoute.unlock);
      expect(harness.controller.isUnlocked, isFalse);
    });

    testWidgets('the right passphrase opens the vault', (tester) async {
      await pumpUnlock(tester, harness);

      await tester.enterText(find.byType(TextField), UnlockHarness.passphrase);
      await tapAndAwait(tester, find.text('Open the chest'), harness.controller);

      expect(harness.controller.isUnlocked, isTrue);
      expect(harness.controller.route, ChestRoute.vault);
    });

    testWidgets('no biometric button is offered when the device cannot prompt',
        (tester) async {
      await pumpUnlock(tester, harness);

      expect(find.text('Confirm with biometrics'), findsNothing);
    });
  });

  group('unlock screen with biometrics', () {
    late UnlockHarness harness;

    setUp(() async {
      harness = await UnlockHarness.create(biometricsAvailable: true);
    });

    tearDown(() async {
      await harness.dispose();
    });

    testWidgets('offers the prompt when the device supports it', (tester) async {
      await pumpUnlock(tester, harness);

      expect(find.text('Confirm with biometrics'), findsOneWidget);
    });

    testWidgets('a successful prompt still requires the passphrase', (tester) async {
      await pumpUnlock(tester, harness);

      // The screen prompts automatically on open when biometrics are enabled,
      // so the snackbar from that first prompt is already on screen.
      expect(find.textContaining('Identity confirmed'), findsOneWidget);
      expect(harness.controller.isUnlocked, isFalse);
    });
  });
}
