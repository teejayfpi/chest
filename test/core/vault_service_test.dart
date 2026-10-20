import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chest/core/vault_service.dart';
import 'package:chest/crypto/crypto_primitives.dart';
import 'package:chest/crypto/key_derivation.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  late Directory tempDir;
  late VaultService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('chest_vault_test_');
    service = VaultService(directory: tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('vault lifecycle', () {
    test('does not exist before creation', () async {
      expect(await service.exists(), isFalse);
      expect(await service.readDescriptor(), isNull);
    });

    test('creates, unlocks and re-locks', () async {
      final session = await service.create(
        passphrase: 'a strong passphrase',
        profile: KdfProfile.standard,
      );
      expect(await service.exists(), isTrue);
      expect(session.descriptor.kdfProfileId, equals(KdfProfile.standard.id));
      session.dispose();

      final reopened = await service.unlock(passphrase: 'a strong passphrase');
      expect(await service.listEntries(reopened), isEmpty);
      reopened.dispose();
    });

    test('refuses to unlock with the wrong passphrase', () async {
      final session = await service.create(
        passphrase: 'correct',
        profile: KdfProfile.standard,
      );
      session.dispose();

      await expectLater(
        service.unlock(passphrase: 'incorrect'),
        throwsA(isA<ChestAuthenticationException>()),
      );
    });

    test('refuses to create a second vault over an existing one', () async {
      final session = await service.create(
        passphrase: 'pw',
        profile: KdfProfile.standard,
      );
      session.dispose();
      await expectLater(
        service.create(passphrase: 'pw', profile: KdfProfile.standard),
        throwsA(isA<ChestCryptoException>()),
      );
    });

    test('uses a fresh salt per vault', () async {
      final a = await service.create(passphrase: 'pw', profile: KdfProfile.standard);
      final saltA = a.descriptor.salt;
      a.dispose();

      final otherDir = await Directory.systemTemp.createTemp('chest_vault_test_');
      addTearDown(() => otherDir.delete(recursive: true));
      final other = VaultService(directory: otherDir);
      final b = await other.create(passphrase: 'pw', profile: KdfProfile.standard);
      b.dispose();

      expect(saltA, isNot(equals(b.descriptor.salt)));
    });

    test('descriptor survives a round-trip through JSON', () async {
      final session = await service.create(
        passphrase: 'pw',
        profile: KdfProfile.standard,
      );
      session.dispose();
      final descriptor = await service.readDescriptor();
      expect(descriptor, isNotNull);
      expect(descriptor!.version, equals(VaultService.descriptorVersion));
      expect(descriptor.profile, equals(KdfProfile.standard));
    });
  });

  group('file storage', () {
    test('adds, reads and deletes a file', () async {
      final session = await service.create(
        passphrase: 'pw',
        profile: KdfProfile.standard,
      );
      final data = bytesOf('the crown jewels');
      final entry = await service.addFile(
        session: session,
        name: 'jewels.txt',
        data: data,
      );

      expect(entry.displayName, equals('jewels.txt'));
      expect(entry.sizeBytes, equals(data.length));
      expect(entry.originalExtension, equals('txt'));

      final read = await service.readFile(session: session, entry: entry);
      expect(read, equals(data));

      await service.deleteFile(session: session, entry: entry);
      expect(await service.listEntries(session), isEmpty);
      session.dispose();
    });

    test('stores the blob encrypted, never as plaintext', () async {
      final session = await service.create(
        passphrase: 'pw',
        profile: KdfProfile.standard,
      );
      const marker = 'PLAINTEXT-MARKER-7C1B';
      await service.addFile(
        session: session,
        name: 'secret.txt',
        data: bytesOf(marker),
      );

      final blobDir =
          Directory('${tempDir.path}/chest_vault/${VaultService.blobDirName}');
      final blobs = await blobDir.list().toList();
      expect(blobs, hasLength(1));
      final raw = await File(blobs.first.path).readAsBytes();
      expect(
        utf8.decode(raw, allowMalformed: true).contains(marker),
        isFalse,
        reason: 'the marker must not appear in the ciphertext',
      );
      session.dispose();
    });

    test('stores the index encrypted, never as plaintext', () async {
      final session = await service.create(
        passphrase: 'pw',
        profile: KdfProfile.standard,
      );
      await service.addFile(
        session: session,
        name: 'IDENTIFIABLE-NAME-QQ77.txt',
        data: bytesOf('x'),
      );
      final indexFile =
          File('${tempDir.path}/chest_vault/${VaultService.indexFile}');
      final raw = utf8.decode(await indexFile.readAsBytes(), allowMalformed: true);
      expect(raw.contains('IDENTIFIABLE-NAME-QQ77'), isFalse);
      session.dispose();
    });

    test('keeps entries across a lock and unlock cycle', () async {
      final session = await service.create(
        passphrase: 'pw',
        profile: KdfProfile.standard,
      );
      final data = bytesOf('persisted payload');
      final entry = await service.addFile(
        session: session,
        name: 'note.md',
        data: data,
      );
      session.dispose();

      final reopened = await service.unlock(passphrase: 'pw');
      final entries = await service.listEntries(reopened);
      expect(entries, hasLength(1));
      expect(entries.first.id, equals(entry.id));
      expect(
        await service.readFile(session: reopened, entry: entries.first),
        equals(data),
      );
      reopened.dispose();
    });

    test('handles several files and deletes only the requested one', () async {
      final session = await service.create(
        passphrase: 'pw',
        profile: KdfProfile.standard,
      );
      final a = await service.addFile(
          session: session, name: 'a.txt', data: bytesOf('aaa'));
      await service.addFile(
          session: session, name: 'b.txt', data: bytesOf('bbb'));
      await service.addFile(
          session: session, name: 'c.txt', data: bytesOf('ccc'));

      await service.deleteFile(session: session, entry: a);
      final remaining = (await service.listEntries(session))
          .map((e) => e.displayName)
          .toList()
        ..sort();
      expect(remaining, equals(['b.txt', 'c.txt']));
      session.dispose();
    });

    test('detects a tampered blob', () async {
      final session = await service.create(
        passphrase: 'pw',
        profile: KdfProfile.standard,
      );
      final entry = await service.addFile(
        session: session,
        name: 'x.bin',
        data: bytesOf('payload'),
      );
      final blob = File(
          '${tempDir.path}/chest_vault/${VaultService.blobDirName}/${entry.id}.chest');
      final raw = Uint8List.fromList(await blob.readAsBytes());
      raw[raw.length - 40] ^= 0xff;
      await blob.writeAsBytes(raw);

      await expectLater(
        service.readFile(session: session, entry: entry),
        throwsA(isA<ChestAuthenticationException>()),
      );
      session.dispose();
    });

    test('rejects a blob moved between vaults', () async {
      final session = await service.create(
        passphrase: 'pw',
        profile: KdfProfile.standard,
      );
      final entry = await service.addFile(
        session: session,
        name: 'bound.txt',
        data: bytesOf('vault-bound'),
      );

      // A second vault has its own salt, so its session cannot open this blob:
      // the per-vault AAD binding must reject it.
      final otherDir = await Directory.systemTemp.createTemp('chest_vault_other_');
      addTearDown(() => otherDir.delete(recursive: true));
      final other = VaultService(directory: otherDir);
      final otherSession =
          await other.create(passphrase: 'pw', profile: KdfProfile.standard);

      final container = await File(
              '${tempDir.path}/chest_vault/${VaultService.blobDirName}/${entry.id}.chest')
          .readAsBytes();
      await expectLater(
        otherSession.open(container),
        throwsA(isA<ChestAuthenticationException>()),
      );
      session.dispose();
      otherSession.dispose();
    });

    test('search matches by exact and partial name', () async {
      final session = await service.create(
        passphrase: 'pw',
        profile: KdfProfile.standard,
      );
      await service.addFile(
          session: session, name: 'tax-return-2024.pdf', data: bytesOf('a'));
      await service.addFile(
          session: session, name: 'holiday.jpg', data: bytesOf('b'));

      final exact = await service.search(session: session, query: 'holiday.jpg');
      expect(exact, hasLength(1));
      expect(exact.first.displayName, equals('holiday.jpg'));

      final partial = await service.search(session: session, query: 'tax');
      expect(partial, hasLength(1));
      expect(partial.first.displayName, equals('tax-return-2024.pdf'));

      final none = await service.search(session: session, query: 'absent');
      expect(none, isEmpty);
      session.dispose();
    });

    test('name index is stable and keyed', () async {
      final session = await service.create(
        passphrase: 'pw',
        profile: KdfProfile.standard,
      );
      final first = await session.nameIndexFor('Report.PDF');
      final second = await session.nameIndexFor('  report.pdf  ');
      expect(first, equals(second),
          reason: 'normalisation must fold case and trim space');

      final otherDir = await Directory.systemTemp.createTemp('chest_vault_other_');
      addTearDown(() => otherDir.delete(recursive: true));
      final other = VaultService(directory: otherDir);
      final otherSession =
          await other.create(passphrase: 'pw', profile: KdfProfile.standard);
      expect(await otherSession.nameIndexFor('report.pdf'), isNot(equals(first)),
          reason: 'a different vault key must produce a different index');

      session.dispose();
      otherSession.dispose();
    });
  });

  group('session disposal', () {
    test('rejects use after dispose', () async {
      final session = await service.create(
        passphrase: 'pw',
        profile: KdfProfile.standard,
      );
      session.dispose();
      expect(
        () => session.seal(bytesOf('x')),
        throwsA(isA<VaultLockedException>()),
      );
    });

    test('zeroes the root key on dispose', () async {
      final session = await service.create(
        passphrase: 'pw',
        profile: KdfProfile.standard,
      );
      final keyBuffer = session.rootKey;
      expect(keyBuffer.any((b) => b != 0), isTrue,
          reason: 'a real key should not be all zeroes');
      session.dispose();
      expect(keyBuffer.every((b) => b == 0), isTrue,
          reason: 'dispose must zero the live buffer in place');
    });
  });

  group('destroy', () {
    test('removes the vault from disk', () async {
      final session = await service.create(
        passphrase: 'pw',
        profile: KdfProfile.standard,
      );
      await service.addFile(session: session, name: 'x.txt', data: bytesOf('x'));
      session.dispose();

      await service.destroy();
      expect(await service.exists(), isFalse);
    });
  });
}
