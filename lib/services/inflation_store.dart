import '../models/inflation.dart';
import 'local_file_store.dart';
import 'mutex.dart';

/// `inflation.json` persistence: the price series of each country looked
/// up so far, by country code. All read-modify-write access is serialized
/// through one mutex, so two countries refreshed at once never overwrite
/// each other.
class InflationStore {
  static const String _fileName = 'inflation.json';
  final Mutex _mutex = Mutex();

  Future<Map<String, InflationSeries>> load() async {
    final json = await LocalFileStore.readJson(_fileName);
    final countries = json?['countries'];
    if (countries is! Map<String, dynamic>) return {};
    final out = <String, InflationSeries>{};
    countries.forEach((country, value) {
      // A country that cannot be read is fetched again; the others stay.
      try {
        out[country] = InflationSeries.fromJson(country, value as Map<String, dynamic>);
      } catch (_) {}
    });
    return out;
  }

  /// Applies [apply] to the freshest on-disk copy of [country]'s series
  /// and persists the result if it changed. Returns the series either way.
  Future<InflationSeries> update(String country, InflationSeries Function(InflationSeries? current) apply) {
    return _mutex.synchronized(() async {
      final all = await load();
      final updated = apply(all[country]);
      if (updated != all[country]) {
        all[country] = updated;
        await LocalFileStore.writeJson(_fileName, {
          'countries': {for (final entry in all.entries) entry.key: entry.value.toJson()},
        });
      }
      return updated;
    });
  }
}
