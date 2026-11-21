import 'package:qima/models/book_account.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/models/entry_builder.dart';
import 'package:qima/models/holding_entry_codec.dart';
import 'package:qima/models/ledger.dart';

/// The cash side of a trade as an earlier build kept it: a `holding_trade`
/// entry between [account] and Holdings, in the account's currency. [amount]
/// leaves [account] (a buy or a fee) or, with [incoming], comes back (a
/// sell). Test fixture only; the app no longer writes this entry.
BookEntry oldHoldingTrade(
  EntryBuilder builder,
  BookAccount account,
  int amount,
  DateTime date, {
  required bool incoming,
  required String id,
  String merchant = '',
}) {
  final currency = account.currency!;
  final signed = incoming ? amount : -amount;
  return BookEntry(
    id: id,
    date: date,
    template: EntryTemplate.holdingTrade,
    baseCurrency: builder.baseCurrency,
    lines: [
      EntryLine(accountId: account.id, amount: signed, currency: currency, baseAmount: builder.toBase(signed, currency)),
      EntryLine(accountId: SystemAccount.holdings.id, amount: -signed, currency: currency, baseAmount: builder.toBase(-signed, currency)),
    ],
    merchant: merchant,
  );
}

/// The ledger of the trade entries among [entries], read back through
/// `HoldingEntryCodec`: other entries, declined ones, and trades that cannot
/// be read are left out.
Ledger ledgerOfEntries(Iterable<BookEntry> entries) => Ledger.derive([
      for (final e in entries)
        if (e.counts && HoldingEntryCodec.isHoldingEntry(e)) ?HoldingEntryCodec.tryFromEntry(e),
    ]);
