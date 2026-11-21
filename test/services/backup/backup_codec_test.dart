import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:qima/l10n/app_localizations_en.dart';
import 'package:qima/models/backup.dart';
import 'package:qima/services/backup/backup_codec.dart';

BackupPayload _payload() => const BackupPayload(
      watchcards: [
        {
          'item': {'id': 'c1', 'instrumentID': 'metal.XAU', 'currency': 'USD', 'unit': 'troyOunce', 'karat': null},
          'order': 0.0,
          'updatedAt': '2026-01-01T00:00:00.000Z',
          'deleted': false,
        },
      ],
      customInstruments: [],
      alerts: [],
      settings: BackupSettings(
        baseCurrency: 'USD',
        appLanguage: 'system',
        appearance: 'system',
        preferredChartRange: 'month1',
        widgetRefreshInterval: 15,
      ),
      book: {'accounts': [], 'entries': [], 'recurring': [], 'settings': []},
    );

const _app = BackupAppInfo(version: '1.2.0', build: '42');

/// Every `encodeEncrypted` call below passes this instead of the production
/// 600,000-iteration default — see `BackupCrypto.encrypt`'s doc comment.
/// This file only exercises the codec's own encode/decode/error-mapping
/// logic, not the KDF's cost, and the on-disk format is unaffected either
/// way: `kdf.iterations` is always read back from the file on decode.
const _testKdfIterations = 10;

void main() {
  final l10n = AppLocalizationsEn();

  group('plain round trip', () {
    test('encodes and decodes back to the same payload', () async {
      final json = BackupCodec.encodePlain(payload: _payload(), app: _app);
      final envelope = BackupCodec.parseEnvelope(json);

      expect(envelope.encrypted, isFalse);
      expect(envelope.app.version, '1.2.0');
      expect(envelope.app.build, '42');

      final decoded = await BackupCodec.decodePayload(envelope);
      expect(decoded.watchcards, _payload().watchcards);
      expect(decoded.settings.baseCurrency, 'USD');
    });
  });

  group('version 4', () {
    test('writes version 4 with the book and neither a holdings nor a transactions list', () {
      final file = jsonDecode(BackupCodec.encodePlain(payload: _payload(), app: _app)) as Map<String, dynamic>;
      expect(file['version'], 4);
      final payload = file['payload'] as Map<String, dynamic>;
      expect(payload.keys.toSet(), {'watchcards', 'customInstruments', 'alerts', 'settings', 'book'});
    });

    test('reads a file with no holdings list, and ignores one a hand-edited file adds', () async {
      final file = jsonDecode(BackupCodec.encodePlain(payload: _payload(), app: _app)) as Map<String, dynamic>;
      expect((await BackupCodec.decodePayload(BackupCodec.parseEnvelope(jsonEncode(file)))).isLedger, isTrue);
      (file['payload'] as Map<String, dynamic>)['holdings'] = [{'bogus': true}];
      (file['payload'] as Map<String, dynamic>)['transactions'] = [{'bogus': true}];
      final decoded = await BackupCodec.decodePayload(BackupCodec.parseEnvelope(jsonEncode(file)));
      expect(decoded.isLedger, isTrue);
      expect(decoded.holdings, isEmpty);
      expect(decoded.transactions, isNull);
    });

    test('a file with no book is corrupted', () async {
      final file = jsonDecode(BackupCodec.encodePlain(payload: _payload(), app: _app)) as Map<String, dynamic>;
      (file['payload'] as Map<String, dynamic>).remove('book');
      await expectLater(
        () => BackupCodec.decodePayload(BackupCodec.parseEnvelope(jsonEncode(file))),
        throwsA(isA<BackupError>().having((e) => e.kind, 'kind', BackupErrorKind.corrupted)),
      );
    });

    test('a file with version 5 is refused with the newer-version error', () {
      final file = jsonDecode(BackupCodec.encodePlain(payload: _payload(), app: _app)) as Map<String, dynamic>;
      file['version'] = 5;
      expect(
        () => BackupCodec.parseEnvelope(jsonEncode(file)),
        throwsA(isA<BackupError>().having((e) => e.kind, 'kind', BackupErrorKind.newerVersion)),
      );
    });

    test('version 3 still needs its holdings list', () async {
      final json = jsonEncode({
        'format': 'qima-backup',
        'version': 3,
        'createdAt': '2026-03-10T00:00:00.000Z',
        'app': {'version': '4.0.0', 'build': '1'},
        'encrypted': false,
        'payload': _payload().toJson(),
      });
      await expectLater(
        () => BackupCodec.decodePayload(BackupCodec.parseEnvelope(json)),
        throwsA(isA<BackupError>().having((e) => e.kind, 'kind', BackupErrorKind.corrupted)),
      );
    });
  });

  group('encrypted round trip', () {
    test('encodes and decodes back to the same payload with the right password', () async {
      final json = await BackupCodec.encodeEncrypted(
        payload: _payload(),
        app: _app,
        password: 'correct horse',
        kdfIterations: _testKdfIterations,
      );
      final envelope = BackupCodec.parseEnvelope(json);

      expect(envelope.encrypted, isTrue);

      final decoded = await BackupCodec.decodePayload(envelope, password: 'correct horse');
      expect(decoded.watchcards, _payload().watchcards);
    });

    test('wrong password fails with BackupErrorKind.wrongPassword', () async {
      final json = await BackupCodec.encodeEncrypted(
        payload: _payload(),
        app: _app,
        password: 'correct horse',
        kdfIterations: _testKdfIterations,
      );
      final envelope = BackupCodec.parseEnvelope(json);

      await expectLater(
        () => BackupCodec.decodePayload(envelope, password: 'wrong password'),
        throwsA(isA<BackupError>().having((e) => e.kind, 'kind', BackupErrorKind.wrongPassword)),
      );
    });

    test('empty password fails with BackupErrorKind.wrongPassword', () async {
      final json = await BackupCodec.encodeEncrypted(
        payload: _payload(),
        app: _app,
        password: 'correct horse',
        kdfIterations: _testKdfIterations,
      );
      final envelope = BackupCodec.parseEnvelope(json);

      await expectLater(
        () => BackupCodec.decodePayload(envelope, password: ''),
        throwsA(isA<BackupError>().having((e) => e.kind, 'kind', BackupErrorKind.wrongPassword)),
      );
    });

    test('tampered ciphertext fails with BackupErrorKind.wrongPassword (GCM tag mismatch)', () async {
      final json = await BackupCodec.encodeEncrypted(
        payload: _payload(),
        app: _app,
        password: 'correct horse',
        kdfIterations: _testKdfIterations,
      );
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      final payload = decoded['payload'] as Map<String, dynamic>;
      // Flip one character of the base64 ciphertext.
      final ciphertext = payload['ciphertext'] as String;
      final flipped = (ciphertext[0] == 'A' ? 'B' : 'A') + ciphertext.substring(1);
      payload['ciphertext'] = flipped;
      final tamperedJson = jsonEncode(decoded);

      final envelope = BackupCodec.parseEnvelope(tamperedJson);
      await expectLater(
        () => BackupCodec.decodePayload(envelope, password: 'correct horse'),
        throwsA(isA<BackupError>().having((e) => e.kind, 'kind', BackupErrorKind.wrongPassword)),
      );
    });

    test('different encryptions of the same payload produce different ciphertext', () async {
      final json1 = await BackupCodec.encodeEncrypted(
        payload: _payload(),
        app: _app,
        password: 'pw',
        kdfIterations: _testKdfIterations,
      );
      final json2 = await BackupCodec.encodeEncrypted(
        payload: _payload(),
        app: _app,
        password: 'pw',
        kdfIterations: _testKdfIterations,
      );
      final e1 = jsonDecode(json1)['payload']['ciphertext'];
      final e2 = jsonDecode(json2)['payload']['ciphertext'];
      expect(e1, isNot(equals(e2)));
    });
  });

  group('format errors', () {
    test('non-JSON input fails with BackupErrorKind.notQimaFile', () {
      expect(
        () => BackupCodec.parseEnvelope('not json at all'),
        throwsA(isA<BackupError>().having((e) => e.kind, 'kind', BackupErrorKind.notQimaFile)),
      );
    });

    test('CSV input fails with BackupErrorKind.notQimaFile', () {
      const csv = 'Instrument,Symbol,Quantity\nGold,XAU,1';
      expect(
        () => BackupCodec.parseEnvelope(csv),
        throwsA(isA<BackupError>().having((e) => e.kind, 'kind', BackupErrorKind.notQimaFile)),
      );
    });

    test('valid JSON missing the format marker fails with BackupErrorKind.notQimaFile', () {
      final json = jsonEncode({'foo': 'bar'});
      expect(
        () => BackupCodec.parseEnvelope(json),
        throwsA(isA<BackupError>().having((e) => e.kind, 'kind', BackupErrorKind.notQimaFile)),
      );
    });

    test('a foreign JSON file with the wrong format string fails with BackupErrorKind.notQimaFile', () {
      final json = jsonEncode({
        'format': 'some-other-app-backup',
        'version': 1,
        'createdAt': DateTime.now().toIso8601String(),
        'app': {'version': '1.0', 'build': '1'},
        'encrypted': false,
        'payload': {},
      });
      expect(
        () => BackupCodec.parseEnvelope(json),
        throwsA(isA<BackupError>().having((e) => e.kind, 'kind', BackupErrorKind.notQimaFile)),
      );
    });

    test('newer version fails with BackupErrorKind.newerVersion', () {
      final json = jsonEncode({
        'format': 'qima-backup',
        'version': BackupEnvelope.currentVersion + 1,
        'createdAt': DateTime.now().toIso8601String(),
        'app': {'version': '9.9.9', 'build': '999'},
        'encrypted': false,
        'payload': {},
      });
      expect(
        () => BackupCodec.parseEnvelope(json),
        throwsA(isA<BackupError>().having((e) => e.kind, 'kind', BackupErrorKind.newerVersion)),
      );
    });

    test('missing required fields in the payload fails with BackupErrorKind.corrupted', () async {
      final json = jsonEncode({
        'format': 'qima-backup',
        'version': 1,
        'createdAt': DateTime.now().toIso8601String(),
        'app': {'version': '1.0', 'build': '1'},
        'encrypted': false,
        'payload': {'watchcards': []}, // missing holdings/customInstruments/alerts/settings
      });
      final envelope = BackupCodec.parseEnvelope(json);
      await expectLater(
        () => BackupCodec.decodePayload(envelope),
        throwsA(isA<BackupError>().having((e) => e.kind, 'kind', BackupErrorKind.corrupted)),
      );
    });

    test('every error kind resolves to a distinct, non-empty localized message', () {
      final messages = BackupErrorKind.values.map((kind) => BackupError(kind).message(l10n)).toSet();
      expect(messages.length, BackupErrorKind.values.length);
      expect(messages.every((m) => m.isNotEmpty), isTrue);
    });
  });
}
