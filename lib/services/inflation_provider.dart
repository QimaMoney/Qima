import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/inflation.dart';

/// Errors surfaced by an inflation source.
class InflationError implements Exception {
  final String kind; // 'unsupportedCountry' | 'invalidResponse' | 'decodingFailed'
  final String? detail;

  const InflationError.unsupportedCountry(String country)
      : kind = 'unsupportedCountry',
        detail = country;

  const InflationError.invalidResponse()
      : kind = 'invalidResponse',
        detail = null;

  const InflationError.decodingFailed()
      : kind = 'decodingFailed',
        detail = null;

  @override
  String toString() => detail == null ? 'InflationError.$kind' : 'InflationError.$kind($detail)';
}

const Duration _requestTimeout = Duration(seconds: 30);

final RegExp _countryPattern = RegExp(r'^[A-Z]{3}$');

/// [country] as the ISO 3166-1 alpha-3 code both sources take. The code
/// goes into a request path, so anything else is refused here.
String inflationCountryCode(String country) {
  final code = country.trim().toUpperCase();
  if (!_countryPattern.hasMatch(code)) throw InflationError.unsupportedCountry(country);
  return code;
}

/// Consumer price index levels by month, quarter and year, from the IMF's
/// CPI dataset (keyless). The headline, all-items national index.
///
/// An empty answer means the IMF has no such series for the country. A
/// failure to get an answer at all throws, so the two are never confused.
class ImfCpiProvider {
  final http.Client client;
  final String baseUrl;

  ImfCpiProvider({http.Client? client, this.baseUrl = 'https://api.imf.org/external/sdmx/2.1/data/CPI'})
      : client = client ?? http.Client();

  static const Map<String, InflationFrequency> _frequencies = {
    'M': InflationFrequency.monthly,
    'Q': InflationFrequency.quarterly,
    'A': InflationFrequency.annual,
  };

  Future<Map<InflationPeriod, double>> index(String country) async {
    // Country, index type, all items, index level; the frequency is left
    // open so one request brings the monthly, quarterly and yearly series.
    final uri = Uri.parse('$baseUrl/${inflationCountryCode(country)}.CPI._T.IX.');
    final response = await client.get(uri, headers: const {'Accept': 'application/json'}).timeout(_requestTimeout);
    // The IMF answers a country it has no series for with 400, not 404.
    if (response.statusCode == 400 || response.statusCode == 404) return const {};
    if (response.statusCode != 200) throw const InflationError.invalidResponse();
    try {
      return _decode(jsonDecode(response.body) as Map<String, dynamic>);
    } catch (_) {
      throw const InflationError.decodingFailed();
    }
  }

  /// Reads an SDMX-JSON message: each series is keyed by the positions of
  /// its dimension values, and each observation by the position of its
  /// period in the shared list of periods.
  Map<InflationPeriod, double> _decode(Map<String, dynamic> json) {
    final dataSets = json['dataSets'] as List<dynamic>? ?? const [];
    if (dataSets.isEmpty) return const {};
    final dimensions = (json['structure'] as Map<String, dynamic>)['dimensions'] as Map<String, dynamic>;
    List<String> ids(Map<String, dynamic> dimension) =>
        [for (final value in dimension['values'] as List<dynamic>) (value as Map<String, dynamic>)['id'] as String];

    final seriesDimensions = (dimensions['series'] as List<dynamic>).cast<Map<String, dynamic>>();
    final frequencyPosition = seriesDimensions.indexWhere((dimension) => dimension['id'] == 'FREQUENCY');
    if (frequencyPosition < 0) throw const InflationError.decodingFailed();
    final frequencyIds = ids(seriesDimensions[frequencyPosition]);
    final periodIds = ids((dimensions['observation'] as List<dynamic>).first as Map<String, dynamic>);

    final out = <InflationPeriod, double>{};
    final allSeries = (dataSets.first as Map<String, dynamic>)['series'] as Map<String, dynamic>? ?? const {};
    allSeries.forEach((seriesKey, series) {
      final frequency = _frequencies[frequencyIds[int.parse(seriesKey.split(':')[frequencyPosition])]];
      if (frequency == null) return;
      final observations = (series as Map<String, dynamic>)['observations'] as Map<String, dynamic>? ?? const {};
      observations.forEach((position, observation) {
        final period = InflationPeriod.tryParse(periodIds[int.parse(position)]);
        final level = _number((observation as List<dynamic>).first);
        // A level that is not above zero cannot be divided by, and a period
        // named for another frequency does not belong to this series.
        if (period == null || period.frequency != frequency || level == null || level <= 0) return;
        out[period] = level;
      });
    });
    return out;
  }

  /// The feed writes its figures as text.
  static double? _number(Object? value) => switch (value) {
        final num n => n.toDouble(),
        final String s => double.tryParse(s),
        _ => null,
      };
}

/// Yearly consumer price inflation by year, as fractions, from the World
/// Bank's `FP.CPI.TOTL.ZG` indicator (keyless). It reaches further back
/// than the IMF index for many countries, and covers some the IMF lacks.
///
/// An empty answer means the World Bank has no figures for the country. A
/// failure to get an answer at all throws.
class WorldBankInflationProvider {
  final http.Client client;
  final String baseUrl;

  WorldBankInflationProvider({http.Client? client, this.baseUrl = 'https://api.worldbank.org/v2'})
      : client = client ?? http.Client();

  /// More than the years the indicator has (it starts in 1960), so the
  /// whole history comes in one page.
  static const int _pageSize = 500;

  Future<Map<int, double>> annualRates(String country) async {
    final uri = Uri.parse(
      '$baseUrl/country/${inflationCountryCode(country)}/indicator/FP.CPI.TOTL.ZG?format=json&per_page=$_pageSize',
    );
    final response = await client.get(uri).timeout(_requestTimeout);
    if (response.statusCode != 200) throw const InflationError.invalidResponse();
    try {
      // The answer is a pair: paging details, then the rows. A country the
      // World Bank does not know, or has nothing for, comes without rows.
      final json = jsonDecode(response.body) as List<dynamic>;
      final rows = json.length > 1 ? json[1] as List<dynamic>? : null;
      final out = <int, double>{};
      for (final row in rows ?? const <dynamic>[]) {
        final year = int.tryParse('${(row as Map<String, dynamic>)['date']}');
        final percent = row['value'];
        if (year != null && percent is num) out[year] = percent / 100;
      }
      return out;
    } catch (_) {
      throw const InflationError.decodingFailed();
    }
  }
}
