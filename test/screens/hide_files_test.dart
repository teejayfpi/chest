import 'dart:io';

import 'package:chest/core/vault_service.dart';
import 'package:chest/crypto/key_derivation.dart';
import 'package:chest/platform/chest_files_bridge.dart';
import 'package:chest/state/chest_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what the native side was asked to do, so a test can assert on the
/// order of operations and not only on the final state.
class FakeFilesChannel {
  FakeFilesChannel() {
    _install();
  }

  static const MethodChannel channel = MethodChannel('com.chest.chest/files');

  /// Every method name in the order it was invoked.
  final List<String> calls = [];

  /// Files the picker will return.
  List<Map<String, Object?>> picks = [];

  /// Bytes returned for any `readPickedFile`.
  Uint8List bytes = Uint8List.fromList(List.generate(64, (i) => i));

  /// When non-null, `readPickedFile` fails with this code.
  String? readErrorCode;

  /// When non-null, `deleteSource` reports the original was not removed.
  String? deleteFailureReason;

  void _install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'pickFiles':
          return picks;
        case 'readPickedFile':
          if (readErrorCode != null) {
            throw PlatformException(code: readErrorCode!);
          }
          return bytes;
        case 'deleteSource':
          return {
            'removed': deleteFailureReason == null,
            'reason': deleteFailureReason,
          };
        case 'releaseSource':
          return true;
        default:
          return null;
      }
    });
  }

  void remove() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

/// A real unlocked vault, so the seal path exercises the actual cipher.
class HideHarness {
  HideHarness._(this.directory, this.controller, this.channel);

  final Directory directory;
  final ChestController controller;
  final FakeFilesChannel channel;

  static const String passphrase = 'the-correct-horse-battery';

  static Future<HideHarness> unlocked() async {
    final directory = await Directory.systemTemp.createTemp('chest_hide_test_');
    final channel = FakeFilesChannel();
    final controller = ChestController(
      vaultService: VaultService(directory: directory),
    )..setProfile(KdfProfile.standard);

    final created = await controller.createVault(passphrase);
    expect(created, isTrue, reason: 'the fixture vault should be created');
    return HideHarness._(directory, controller, channel);
  }

  Future<void> dispose() async {
    controller.dispose();
    channel.remove();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

/// A picked file as the native side would describe it.
Map<String, Object?> pick(String name) => {
      'uri': 'content://com.android.providers.media.documents/document/$name',
      'name': name,
      'size': 64,
      'mimeType': 'image/jpeg',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HideHarness harness;

  setUp(() async {
    harness = await HideHarness.unlocked();
  });

  tearDown(() async {
    await harness.dispose();
  });

  group('hiding picked files', () {
    test('seals the file and removes the original', () async {
      harness.channel.picks = [pick('holiday.jpg')];

      final picks = await harness.controller.pickFilesToHide();
      expect(picks, hasLength(1));
      expect(picks.single.name, 'holiday.jpg');

      final summary = await harness.controller.hidePickedFiles(picks);

      expect(summary.sealed, 1);
      expect(summary.hidden, 1);
      expect(summary.stillVisible, isEmpty);
      expect(summary.failures, isEmpty);
      expect(summary.fullyHidden, isTrue);

      // The bytes really are in the vault, decryptable under the same name.
      final entries = harness.controller.entries;
      expect(entries, hasLength(1));
      expect(entries.single.displayName, 'holiday.jpg');
      final restored = await harness.controller.readFile(entries.single);
      expect(restored, equals(harness.channel.bytes));
    });

    test('seals before it deletes, so a failure can lose nothing', () async {
      harness.channel.picks = [pick('holiday.jpg')];
      final picks = await harness.controller.pickFilesToHide();

      await harness.controller.hidePickedFiles(picks);

      final readIndex = harness.channel.calls.indexOf('readPickedFile');
      final deleteIndex = harness.channel.calls.indexOf('deleteSource');
      expect(readIndex, isNonNegative);
      expect(deleteIndex, isNonNegative);
      expect(
        readIndex,
        lessThan(deleteIndex),
        reason: 'the original must only be deleted once the vault holds the bytes',
      );
    });

    test('reports a sealed file whose original survived as still visible',
        () async {
      harness.channel.picks = [pick('holiday.jpg')];
      harness.channel.deleteFailureReason = 'no write permission for this file';
      final picks = await harness.controller.pickFilesToHide();

      final summary = await harness.controller.hidePickedFiles(picks);

      // Sealed, but not hidden: the distinction the UI reports.
      expect(summary.sealed, 1);
      expect(summary.hidden, 0);
      expect(summary.stillVisible, ['holiday.jpg']);
      expect(summary.fullyHidden, isFalse);

      // The entry is kept rather than rolled back, so the user has not lost it.
      expect(harness.controller.entries, hasLength(1));
    });

    test('seals nothing and reports why when a file cannot be read', () async {
      harness.channel.picks = [pick('huge.mp4')];
      harness.channel.readErrorCode = 'file_too_large';
      final picks = await harness.controller.pickFilesToHide();

      final summary = await harness.controller.hidePickedFiles(picks);

      expect(summary.sealed, 0);
      expect(summary.didNothing, isFalse);
      expect(summary.failures, hasLength(1));
      expect(summary.failures.single, contains('huge.mp4'));
      // The message is the human one, not the raw code.
      expect(summary.failures.single, contains('too large'));
      expect(harness.controller.entries, isEmpty);

      // Nothing was sealed, so the original must not have been deleted.
      expect(harness.channel.calls, isNot(contains('deleteSource')));
    });

    test('releases the grant after sealing so no standing access remains',
        () async {
      harness.channel.picks = [pick('holiday.jpg')];
      final picks = await harness.controller.pickFilesToHide();

      await harness.controller.hidePickedFiles(picks);

      expect(harness.channel.calls, contains('releaseSource'));
    });

    test('drops the grant for files the user chose not to seal', () async {
      harness.channel.picks = [pick('holiday.jpg'), pick('notes.txt')];
      final picks = await harness.controller.pickFilesToHide();
      expect(picks, hasLength(2));

      await harness.controller.discardPicks(picks);

      expect(
        harness.channel.calls.where((c) => c == 'releaseSource').length,
        2,
      );
      expect(harness.channel.calls, isNot(contains('deleteSource')));
      expect(harness.controller.entries, isEmpty);
    });

    test('refuses to seal anything while the vault is locked', () async {
      harness.controller.lock();

      final picks = await harness.controller.pickFilesToHide();

      expect(picks, isEmpty);
      expect(harness.channel.calls, isNot(contains('pickFiles')));
      expect(harness.controller.error, isNotNull);
    });

    test('a cancelled pick changes nothing', () async {
      harness.channel.picks = [];

      final picks = await harness.controller.pickFilesToHide();
      final summary = await harness.controller.hidePickedFiles(picks);

      expect(summary.sealed, 0);
      expect(summary.didNothing, isTrue);
      expect(harness.channel.calls, isNot(contains('deleteSource')));
    });
  });

  group('picked file parsing', () {
    test('reads the provider metadata', () {
      final parsed = PickedFile.fromMap(pick('holiday.jpg'));

      expect(parsed.name, 'holiday.jpg');
      expect(parsed.sizeBytes, 64);
      expect(parsed.sizeKnown, isTrue);
      expect(parsed.mimeType, 'image/jpeg');
      expect(parsed.uri, startsWith('content://'));
    });

    test('tolerates a provider that reports no size', () {
      final parsed = PickedFile.fromMap({
        'uri': 'content://x/1',
        'name': 'mystery.bin',
      });

      expect(parsed.sizeKnown, isFalse);
      expect(parsed.mimeType, 'application/octet-stream');
    });
  });
}
