import '../models/inflation.dart';
import 'inflation_provider.dart';
import 'inflation_store.dart';

/// Inflation by country: the IMF's price index for months, quarters and
/// years, with the World Bank's yearly rates behind it, kept on the device
/// between lookups.
class InflationRepository {
  final ImfCpiProvider _imf;
  final WorldBankInflationProvider _worldBank;
  final InflationStore _store;
  final DateTime Function() _now;
  final Map<(String, bool), Future<InflationSeries>> _inFlight = {};

  InflationRepository({
    ImfCpiProvider? imf,
    WorldBankInflationProvider? worldBank,
    InflationStore? store,
    DateTime Function()? now,
  })  : _imf = imf ?? ImfCpiProvider(),
        _worldBank = worldBank ?? WorldBankInflationProvider(),
        _store = store ?? InflationStore(),
        _now = now ?? DateTime.now;

  /// New figures come out once a month at most, so a copy from the last
  /// day is as good as a new one.
  static const Duration maxAge = Duration(days: 1);

  static final DateTime _never = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  /// The series for [country] (ISO 3166-1 alpha-3). A saved copy younger
  /// than [maxAge] is returned as it is, unless [refresh] is set.
  ///
  /// Never throws for a source that is down: what that source gave last
  /// time is kept, and the next call asks it again. A country neither
  /// source covers comes back empty.
  Future<InflationSeries> series(String country, {bool refresh = false}) {
    final code = inflationCountryCode(country);
    // The block body matters: returning the removed future from the
    // callback would make the lookup wait on itself.
    return _inFlight[(code, refresh)] ??= _series(code, refresh).whenComplete(() {
      _inFlight.remove((code, refresh));
    });
  }

  Future<InflationSeries> _series(String code, bool refresh) async {
    final saved = (await _store.load())[code];
    if (saved != null && !refresh && _now().difference(saved.fetchedAt) < maxAge) return saved;

    final (index, annualRates) = await (_answer(() => _imf.index(code)), _answer(() => _worldBank.annualRates(code))).wait;
    if (index == null && annualRates == null) return saved ?? InflationSeries(country: code, fetchedAt: _never);

    final bothAnswered = index != null && annualRates != null;
    return _store.update(
      code,
      (current) => InflationSeries(
        country: code,
        index: index ?? current?.index ?? const {},
        annualRates: annualRates ?? current?.annualRates ?? const {},
        // Left as it was while a source is still owed, so the next call
        // asks again instead of trusting half an answer for a day.
        fetchedAt: bothAnswered ? _now() : current?.fetchedAt ?? _never,
      ),
    );
  }

  /// What a source said, or null when it could not be reached or read.
  static Future<T?> _answer<T>(Future<T> Function() ask) async {
    try {
      return await ask();
    } catch (_) {
      return null;
    }
  }
}
