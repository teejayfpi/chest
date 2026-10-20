import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the brand assets the UI displays.
///
/// `Image.asset` fails at runtime rather than at build time, and no widget test
/// mounts the Settings screen, so a missing or renamed file would only show up as
/// a broken image on a real device. Loading the bytes here makes that a test
/// failure instead.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const branding = <String>[
    'assets/branding/chest_logo.png',
    'assets/branding/chest_mark.png',
    'assets/branding/chest_splash.png',
  ];

  group('brand assets', () {
    for (final path in branding) {
      test('$path is bundled and is a PNG', () async {
        final data = await rootBundle.load(path);

        expect(data.lengthInBytes, greaterThan(0));

        // PNG magic number, so the file is an image and not a placeholder.
        expect(
          data.buffer.asUint8List(0, 8),
          <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
          reason: '$path is not a PNG',
        );
      });
    }

    test('the logo used by the builder credit card exists', () async {
      // The exact path the Settings credit card loads. Kept as a literal here on
      // purpose: if the widget's path changes, this test should change with it
      // rather than silently passing against a different asset.
      final data = await rootBundle.load('assets/branding/chest_logo.png');
      expect(data.lengthInBytes, greaterThan(0));
    });
  });
}
