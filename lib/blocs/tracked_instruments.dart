import '../models/asset.dart';
import '../models/holding_transaction.dart';
import '../models/instrument_catalog.dart';
import '../models/watch_card.dart';

/// The instruments on [cards], each once, in watchlist order.
List<Instrument> _watchInstrumentsFor(List<WatchCard> cards) {
  final seen = <String>{};
  final result = <Instrument>[];
  for (final card in cards) {
    final instrument = card.instrument;
    if (instrument == null || seen.contains(instrument.id)) continue;
    seen.add(instrument.id);
    result.add(instrument);
  }
  return result;
}

/// Union of watchlist instruments and every instrument with transactions —
/// including ones sold off entirely, whose prices the portfolio history
/// still needs for the days they were held. Holdings can reference an
/// instrument the user removed (or never added) to the watchlist, and
/// without this union they'd be left out of refresh and backfill.
List<Instrument> trackedInstrumentsFor(List<WatchCard> cards, List<HoldingTransaction> transactions) {
  final result = _watchInstrumentsFor(cards);
  final seen = result.map((i) => i.id).toSet();
  for (final transaction in transactions) {
    if (seen.contains(transaction.instrumentID)) continue;
    final instrument = InstrumentCatalog.instrument(transaction.instrumentID);
    if (instrument == null) continue;
    seen.add(instrument.id);
    result.add(instrument);
  }
  return result;
}
