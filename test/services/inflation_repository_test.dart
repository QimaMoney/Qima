import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qima/models/inflation.dart';
import 'package:qima/services/inflation_provider.dart';
import 'package:qima/services/inflation_repository.dart';
import 'package:qima/services/inflation_store.dart';
import 'package:qima/services/local_file_store.dart';

import 'inflation_provider_test.dart' show imfBody;

const _worldBankBody = '[{"page":1,"pages":1},[{"date":"2024","value":28.0},{"date":"2009","value":11.8}]]';

void main() {
  late Directory tempDir;
  late DateTime now;
  late int imfCalls;
  late int worldBankCalls;
  late http.Response Function() imfAnswer;
  late http.Response Function() worldBankAnswer;

  InflationRepository repository() {
    final client = MockClient((request) async {
      if (request.url.host == 'api.imf.org') {
        imfCalls++;
        return imfAnswer();
      }
      worldBankCalls++;
      return worldBankAnswer();
    });
    return InflationRepository(
      imf: ImfCpiProvider(client: client),
      worldBank: WorldBankInflationProvider(client: client),
      now: () => now,
    );
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('qima_inflation_repository_test');
    LocalFileStore.overrideDirectoryForTesting(tempDir);
    now = DateTime.utc(2026, 11, 25, 12);
    imfCalls = 0;
    worldBankCalls = 0;
    imfAnswer = () => http.Response(imfBody(), 200);
    worldBankAnswer = () => http.Response(_worldBankBody, 200);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('joins the index and the yearly rates, and saves them', () async {
    final series = await repository().series('egy');

    expect(series.country, 'EGY');
    expect(series.index[const InflationPeriod.month(2024, 2)], 214.9);
    expect(series.annualRates.keys, [2024, 2009]);
    expect(series.annualRates[2024], closeTo(0.28, 1e-12));
    expect(series.annualRates[2009], closeTo(0.118, 1e-12));
    expect(series.fetchedAt, now);
    expect((await InflationStore().load())['EGY'], series);
  });

  test('prefers the index for a year both sources cover', () async {
    final series = await repository().series('EGY');

    expect(series.rate(const InflationPeriod.year(2024)), closeTo(256.25 / 200.5 - 1, 1e-9));
    expect(series.rate(const InflationPeriod.year(2009)), closeTo(0.118, 1e-12));
  });

  test('returns the saved copy without asking again while it is a day old or less', () async {
    final first = await repository().series('EGY');
    now = now.add(const Duration(hours: 23));

    final second = await repository().series('EGY');

    expect(second, first);
    expect(imfCalls, 1);
    expect(worldBankCalls, 1);
  });

  test('asks again once the saved copy is older than a day, or when told to', () async {
    await repository().series('EGY');
    await repository().series('EGY', refresh: true);
    expect(imfCalls, 2);

    now = now.add(const Duration(days: 1));
    final later = await repository().series('EGY');

    expect(imfCalls, 3);
    expect(later.fetchedAt, now);
  });

  test('falls back to the yearly rates for a country the index does not cover', () async {
    imfAnswer = () => http.Response('{"status":400}', 400);

    final series = await repository().series('TWN');

    expect(series.index, isEmpty);
    expect(series.finestFrequency, InflationFrequency.annual);
    // Both sources answered, so this is settled for the day.
    expect(series.fetchedAt, now);
  });

  test('keeps what a source gave last time while that source is down, and asks it again next time', () async {
    final whole = await repository().series('EGY');
    now = now.add(const Duration(days: 2));
    imfAnswer = () => http.Response('Service Unavailable', 503);
    worldBankAnswer = () => http.Response('[{"page":1},[{"date":"2025","value":14.0}]]', 200);

    final partial = await repository().series('EGY');

    expect(partial.index, whole.index);
    expect(partial.annualRates, {2025: 0.14});
    expect(partial.fetchedAt, whole.fetchedAt);

    imfAnswer = () => http.Response(imfBody(), 200);
    final healed = await repository().series('EGY');
    expect(imfCalls, 3);
    expect(healed.fetchedAt, now);
  });

  test('does not settle for half an answer on a first lookup', () async {
    imfAnswer = () => http.Response('Service Unavailable', 503);

    final partial = await repository().series('EGY');
    expect(partial.index, isEmpty);
    expect(partial.annualRates, isNotEmpty);

    await repository().series('EGY');
    expect(imfCalls, 2);
  });

  test('returns the saved copy when both sources are down', () async {
    final saved = await repository().series('EGY');
    now = now.add(const Duration(days: 2));
    imfAnswer = () => throw const SocketException('offline');
    worldBankAnswer = () => throw const SocketException('offline');

    expect(await repository().series('EGY'), saved);
  });

  test('comes back empty, and saves nothing, when nothing is known and both sources are down', () async {
    imfAnswer = () => throw const SocketException('offline');
    worldBankAnswer = () => throw const SocketException('offline');

    final series = await repository().series('EGY');

    expect(series.isEmpty, isTrue);
    expect(await InflationStore().load(), isEmpty);
  });

  test('asks once when the same country is wanted twice at the same moment', () async {
    final shared = repository();

    final both = await Future.wait([shared.series('EGY'), shared.series('egy')]);

    expect(both.first, both.last);
    expect(imfCalls, 1);
    expect(worldBankCalls, 1);
  });

  test('keeps each country when two are looked up at once', () async {
    final shared = repository();

    await Future.wait([shared.series('EGY'), shared.series('SAU')]);

    expect((await InflationStore().load()).keys, unorderedEquals(['EGY', 'SAU']));
  });

  test('refuses a code that is not a country code', () {
    expect(() => repository().series('Egypt'), throwsA(isA<InflationError>()));
  });

  test('reads the other countries when one saved country is unreadable', () async {
    await repository().series('EGY');
    await LocalFileStore.writeJson('inflation.json', {
      'countries': {
        'EGY': (await InflationStore().load())['EGY']!.toJson(),
        'SAU': {'index': 'not a map'},
      },
    });

    expect((await InflationStore().load()).keys, ['EGY']);
  });
}
