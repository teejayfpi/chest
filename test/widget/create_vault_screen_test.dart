import 'package:chest/crypto/key_derivation.dart';
import 'package:chest/screens/create_vault_screen.dart';
import 'package:chest/state/chest_controller.dart';
import 'package:chest/theme/chest_theme.dart';
import 'package:chest/widgets/chest_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Wraps [child] in the app's theme and a controller.
Widget harness(Widget child, {ChestController? controller}) {
  return ChangeNotifierProvider<ChestController>(
    create: (_) => controller ?? ChestController(),
    child: MaterialApp(
      theme: ChestTheme.dark(),
      home: child,
    ),
  );
}

/// Pumps the create screen on a tall viewport.
///
/// The screen is a long form, and the default 800x600 test surface leaves the
/// lower half unbuilt, so finds would miss widgets that are merely below the
/// fold. A tall, phone-shaped viewport keeps the assertions honest.
Future<void> pumpCreateScreen(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 9000);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(harness(const CreateVaultScreen()));
}

void main() {
  group('passphrase strength', () {
    test('an empty passphrase scores zero', () {
      expect(PassphraseStrengthBar.estimateBits(''), 0);
      expect(PassphraseStrengthBar.score(''), 0);
      expect(PassphraseStrengthBar.label(''), 'Empty');
    });

    test('longer passphrases score higher than shorter ones', () {
      final short = PassphraseStrengthBar.estimateBits('abc123');
      final long = PassphraseStrengthBar.estimateBits('correct horse battery staple');
      expect(long, greaterThan(short));
    });

    test('character diversity raises the estimate', () {
      final narrow = PassphraseStrengthBar.estimateBits('aaaaaaaaaaaaaaaa');
      final wide = PassphraseStrengthBar.estimateBits('aB3!kL9@qW2#zX7%');
      expect(wide, greaterThan(narrow));
    });

    test('repeated characters are discounted', () {
      // Same length, but the distinct-character ratio penalises the repetition.
      final repeated = PassphraseStrengthBar.estimateBits('aaaaaaaaaaaaaaaaaaaa');
      final varied = PassphraseStrengthBar.estimateBits('abcdefghijklmnopqrst');
      expect(varied, greaterThan(repeated));
    });

    test('the score is clamped to the 0..1 range', () {
      expect(PassphraseStrengthBar.score('a'), inInclusiveRange(0.0, 1.0));
      expect(
        PassphraseStrengthBar.score('aB3!kL9@qW2#zX7%' * 8),
        inInclusiveRange(0.0, 1.0),
      );
    });

    test('labels follow the entropy thresholds', () {
      expect(PassphraseStrengthBar.label('aB3!'), 'Weak');
      expect(PassphraseStrengthBar.label('correct horse battery staple'), isNot('Weak'));
    });
  });

  group('create vault screen', () {
    testWidgets('shows the mark, the name and the safety notice', (tester) async {
      await pumpCreateScreen(tester);

      expect(find.text('CHEST'), findsOneWidget);
      expect(find.text('SEALED BY DESIGN'), findsOneWidget);
      expect(find.byType(ChestMark), findsOneWidget);
      expect(find.textContaining('There is no recovery'), findsOneWidget);
      expect(find.text('Create vault'), findsOneWidget);
    });

    testWidgets('rejects a passphrase shorter than the minimum', (tester) async {
      await pumpCreateScreen(tester);

      await tester.enterText(find.byType(TextField).first, 'short');
      await tester.tap(find.text('Create vault'));
      await tester.pump();

      expect(find.text('Use at least 12 characters.'), findsOneWidget);
    });

    testWidgets('rejects a confirmation that does not match', (tester) async {
      await pumpCreateScreen(tester);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'a-perfectly-long-passphrase');
      await tester.enterText(fields.at(1), 'a-different-passphrase-here');
      await tester.tap(find.text('Create vault'));
      await tester.pump();

      expect(find.text('The two passphrases do not match.'), findsOneWidget);
    });

    testWidgets('lists every key-stretching preset', (tester) async {
      await pumpCreateScreen(tester);

      for (final profile in KdfProfile.values) {
        expect(find.text(profile.label), findsOneWidget);
      }
    });

    testWidgets('the strength bar reacts to typing', (tester) async {
      await pumpCreateScreen(tester);

      expect(find.text('Empty'), findsOneWidget);

      await tester.enterText(
        find.byType(TextField).first,
        'correct horse battery staple',
      );
      await tester.pump();

      expect(find.text('Empty'), findsNothing);
      expect(find.textContaining('bits'), findsOneWidget);
    });

    testWidgets('the visibility toggle reveals the passphrase', (tester) async {
      await pumpCreateScreen(tester);

      final firstField = find.byType(TextField).first;
      expect(tester.widget<TextField>(firstField).obscureText, isTrue);

      await tester.tap(find.byTooltip('Show'));
      await tester.pump();

      expect(tester.widget<TextField>(firstField).obscureText, isFalse);
    });
  });
}
