import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qima/models/inflation.dart';
import 'package:qima/services/inflation_provider.dart';

/// An IMF answer in the shape the feed sends: series keyed by the positions
/// of their dimension values, observations by the position of their period.
String imfBody({
  List<String> frequencies = const ['A', 'M', 'Q'],
  List<String> periods = const ['2023', '2024', '2024-M01', '2024-M02', '2024-Q1'],
  Map<String, Map<String, List<Object?>>> series = const {
    '0:0:0:0:0': {
      '0': ['200.5', null, 0],
      '1': ['256.25', null, 0],
    },
    '0:0:0:0:1': {
      '2': ['193', null, 0],
      '3': ['214.9', null, 0],
    },
    '0:0:0:0:2': {
      '4': ['208.3', null, 0],
    },
  },
}) {
  List<Map<String, String>> values(List<String> ids) => [for (final id in ids) {'id': id}];
  return jsonEncode({
    'dataSets': [
      {
        'series': {
          for (final entry in series.entries) entry.key: {'observations': entry.value},
        },
      },
    ],
    'structure': {
      'dimensions': {
        'series': [
          {'id': 'COUNTRY', 'values': values(['EGY'])},
          {'id': 'INDEX_TYPE', 'values': values(['CPI'])},
          {'id': 'COICOP_1999', 'values': values(['_T'])},
          {'id': 'TYPE_OF_TRANSFORMATION', 'values': values(['IX'])},
          {'id': 'FREQUENCY', 'values': values(frequencies)},
        ],
        'observation': [
          {'id': 'TIME_PERIOD', 'values': values(periods)},
        ],
      },
    },
  });
}

void main() {
  group('inflationCountryCode', () {
    test('takes a three letter code in any case', () {
      expect(inflationCountryCode(' egy '), 'EGY');
    });

    test('refuses anything that could change the request', () {
      for (final country in ['', 'EG', 'EGYP', 'E/Y', 'EG?', '../']) {
        expect(
          () => inflationCountryCode(country),
          throwsA(isA<InflationError>().having((e) => e.kind, 'kind', 'unsupportedCountry')),
          reason: country,
        );
      }
    });
  });

  group('ImfCpiProvider', () {
    test('asks for the headline index of one country at every frequency', () async {
      late http.Request sent;
      final client = MockClient((request) async {
        sent = request;
        return http.Response(imfBody(), 200);
      });

      await ImfCpiProvider(client: client).index('egy');

      expect(sent.url.toString(), 'https://api.imf.org/external/sdmx/2.1/data/CPI/EGY.CPI._T.IX.');
      expect(sent.headers['Accept'], 'application/json');
    });

    test('reads the monthly, quarterly and yearly levels', () async {
      final client = MockClient((_) async => http.Response(imfBody(), 200));

      final index = await ImfCpiProvider(client: client).index('EGY');

      expect(index, {
        InflationPeriod.year(2023): 200.5,
        InflationPeriod.year(2024): 256.25,
        InflationPeriod.month(2024, 1): 193.0,
        InflationPeriod.month(2024, 2): 214.9,
        InflationPeriod.quarter(2024, 1): 208.3,
      });
    });

    test('leaves out gaps, levels of zero and frequencies it does not use', () async {
      final body = imfBody(
        frequencies: ['M', 'D'],
        periods: ['2024-M01', '2024-M02', '2024-M03', '2024-M04', '2024'],
        series: {
          '0:0:0:0:0': {
            '0': ['193', null],
            '1': [null, null],
            '2': ['0', null],
            '3': ['n/a', null],
            '4': ['250', null],
          },
          '0:0:0:0:1': {
            '0': ['1', null],
          },
        },
      );
      final client = MockClient((_) async => http.Response(body, 200));

      final index = await ImfCpiProvider(client: client).index('EGY');

      expect(index, {InflationPeriod.month(2024, 1): 193.0});
    });

    test('answers with nothing for a country the IMF has no series for', () async {
      final client = MockClient((_) async => http.Response('{"status":400,"code":40000}', 400));
      expect(await ImfCpiProvider(client: client).index('TWN'), isEmpty);
    });

    test('answers with nothing when the message has no data', () async {
      final client = MockClient((_) async => http.Response('{"dataSets":[]}', 200));
      expect(await ImfCpiProvider(client: client).index('EGY'), isEmpty);
    });

    test('throws when the feed is down, so it is not taken for no data', () async {
      final client = MockClient((_) async => http.Response('Service Unavailable', 503));
      expect(
        ImfCpiProvider(client: client).index('EGY'),
        throwsA(isA<InflationError>().having((e) => e.kind, 'kind', 'invalidResponse')),
      );
    });

    test('throws on an answer it cannot read', () async {
      for (final body in ['<html>', '{"dataSets":[{}]}', '[]']) {
        final client = MockClient((_) async => http.Response(body, 200));
        expect(
          ImfCpiProvider(client: client).index('EGY'),
          throwsA(isA<InflationError>().having((e) => e.kind, 'kind', 'decodingFailed')),
          reason: body,
        );
      }
    });
  });

  group('WorldBankInflationProvider', () {
    test('asks for the whole history of one country in one page', () async {
      late http.Request sent;
      final client = MockClient((request) async {
        sent = request;
        return http.Response('[{"page":1,"pages":1},[]]', 200);
      });

      await WorldBankInflationProvider(client: client).annualRates('egy');

      expect(sent.url.path, '/v2/country/EGY/indicator/FP.CPI.TOTL.ZG');
      expect(sent.url.queryParameters, {'format': 'json', 'per_page': '500'});
    });

    test('reads yearly rates as fractions and leaves out years with no figure', () async {
      const body = '[{"page":1,"pages":1,"total":3},['
          '{"date":"2025","value":14.0735136645933},'
          '{"date":"2024","value":28.2705899322082},'
          '{"date":"1959","value":null}]]';
      final client = MockClient((_) async => http.Response(body, 200));

      final rates = await WorldBankInflationProvider(client: client).annualRates('EGY');

      expect(rates.keys, [2025, 2024]);
      expect(rates[2025], closeTo(0.140735136645933, 1e-12));
      expect(rates[2024], closeTo(0.282705899322082, 1e-12));
    });

    test('answers with nothing for a country it has no figures for or does not know', () async {
      for (final body in [
        '[{"page":0,"pages":0,"per_page":0,"total":0},null]',
        '[{"message":[{"id":"120","key":"Invalid value","value":"The provided parameter value is not valid"}]}]',
      ]) {
        final client = MockClient((_) async => http.Response(body, 200));
        expect(await WorldBankInflationProvider(client: client).annualRates('TWN'), isEmpty, reason: body);
      }
    });

    test('throws when the feed is down or cannot be read', () async {
      final down = MockClient((_) async => http.Response('Bad Gateway', 502));
      expect(
        WorldBankInflationProvider(client: down).annualRates('EGY'),
        throwsA(isA<InflationError>().having((e) => e.kind, 'kind', 'invalidResponse')),
      );
      final garbled = MockClient((_) async => http.Response('<html>', 200));
      expect(
        WorldBankInflationProvider(client: garbled).annualRates('EGY'),
        throwsA(isA<InflationError>().having((e) => e.kind, 'kind', 'decodingFailed')),
      );
    });
  });
}
