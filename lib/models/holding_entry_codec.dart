import 'dart:math' as math;

import 'book_account.dart';
import 'book_entry.dart';
import 'holding_cash_id.dart';
import 'holding_transaction.dart';
import 'metal_breakdown.dart';
import 'minor_units.dart';

/// The cash side of a trade: the account it was paid from or into, in that
/// account's currency, with its worth in the entry's base currency. Both are
/// magnitudes; the kind of the trade gives the direction.
class CashLeg {
  final String accountId;
  final String currency;

  /// Minor units of [currency].
  final int amount;

  /// Minor units of the entry's base currency.
  final int baseAmount;

  const CashLeg({required this.accountId, required this.currency, required this.amount, required this.baseAmount});
}

/// A [HoldingTransaction] as an entry in the books, and back.
///
/// The two are an exact pair: `fromEntry(toEntry(t)) == t` for every field,
/// and the doubles come back bit for bit, except that a negative zero (of a
/// quantity, price or fee) comes back as zero: equal, not the same bits. The
/// sign of nothing is not carried. Where each field lives:
///
/// - `id`, `date`, `note` are the entry's own; `kind` is its template.
/// - `currency` is the currency of the holding line. Without a cash leg it is
///   also the entry's base currency, and the base amount of each line is its
///   amount; with one, the entry's base currency is the cash's (see `toEntry`).
/// - `instrumentID`, `quantity`, `unit`, `karat`, `unitPrice` and `fee` are
///   facts on the line posted to the holding account, `holding.<instrument>`.
///   The quantity is a signed count of 1e-8 of the unit (`qty`); when the
///   number the person entered is not exactly that count it is kept as
///   entered in `qtyRaw` as well.
/// - Cost is money: `qty * price + fee` in minor units of the currency, on
///   the holding line, against `system.holdings`.
///
/// A fee row carries no quantity on its line (its quantity, zero in practice,
/// is read from `qtyRaw` when it is not zero). A row that moves no money (a
/// transfer out, or a transfer in of unknown cost) is a single line that
/// moves quantity only.
///
/// A buy, sell or fee may carry the account it was paid from or into as a
/// [CashLeg]: the other side is then that account and not `system.holdings`.
///
/// A row that moves neither quantity nor money (a fee that rounds to nothing,
/// a buy of nothing) has no valid entry: `toEntry` still writes one, and its
/// `issues` report a zero line.
abstract final class HoldingEntryCodec {
  /// Quantities are counted in this fraction of the unit.
  static const double _scale = 1e8;

  /// Doubles count whole numbers exactly up to here.
  static const double _exactLimit = 9007199254740992;

  /// Beyond this a count no longer fits a signed 64-bit integer.
  static const double _intLimit = 9.2e18;

  static const Map<TransactionKind, EntryTemplate> _templates = {
    TransactionKind.buy: EntryTemplate.holdingBuy,
    TransactionKind.sell: EntryTemplate.holdingSell,
    TransactionKind.transferIn: EntryTemplate.holdingIn,
    TransactionKind.transferOut: EntryTemplate.holdingOut,
    TransactionKind.fee: EntryTemplate.holdingFee,
  };

  /// Whether [entry] is one [fromEntry] reads.
  static bool isHoldingEntry(BookEntry entry) => _templates.containsValue(entry.template);

  /// [t] as an entry. With [cash], the other side of a buy, sell or fee is
  /// the cash account instead of `system.holdings`; a transfer never takes
  /// one, and [cash] is left out of it.
  ///
  /// [baseCurrency] is the entry's base currency when there is a cash leg
  /// (the trade's own currency when left out); without a cash leg it is not
  /// used, because the lines would have no rate to a base currency they are
  /// not in. [merchant] is the instrument label the cash entry carried.
  ///
  /// The two money lines carry equal and opposite base amounts, taken from
  /// whichever side is already in the base currency, else from the cash side
  /// (the rule of `EntryBuilder`). When both are in one currency and the cash
  /// differs from the cost, the difference goes on `system.holdings`. What
  /// cannot balance: a cash leg against a row whose cost is nothing, in
  /// another currency, and a sell whose commission passes its proceeds with
  /// a cash leg in another currency (the base amounts of the two lines then
  /// disagree in sign); `issues` reports both.
  static BookEntry toEntry(HoldingTransaction t, {CashLeg? cash, String? baseCurrency, String merchant = ''}) {
    final currency = t.currency;
    // The money that moves, debit-positive on the holding, and which way the
    // quantity goes (0 for a fee, which has none).
    final (amount, direction) = switch (t.kind) {
      TransactionKind.buy || TransactionKind.transferIn => (_minor(t.totalCost, currency), 1),
      TransactionKind.sell => (-_minor(t.netProceeds, currency), -1),
      TransactionKind.transferOut => (0, -1),
      TransactionKind.fee => (_minor(t.fee, currency), 0),
    };
    // Cash goes down for a buy or fee and up for a sell, whatever the kind of
    // account: a card's debt rising is a negative amount too.
    final cashSign = switch (t.kind) {
      TransactionKind.buy || TransactionKind.fee => -1,
      TransactionKind.sell => 1,
      TransactionKind.transferIn || TransactionKind.transferOut => 0,
    };
    final leg = cash != null && cashSign != 0 ? cash : null;
    final base = leg == null ? currency : (baseCurrency ?? currency);

    // Each side's base amount, and the cash amount.
    final int cashAmount = leg == null ? 0 : cashSign * leg.amount.abs();
    int holdingBase = amount;
    int cashBase = 0;
    if (leg != null) {
      if (currency == base) {
        holdingBase = amount;
        cashBase = leg.currency == base ? cashAmount : -amount;
      } else if (leg.currency == base) {
        cashBase = cashAmount;
        holdingBase = -cashAmount;
      } else {
        cashBase = cashSign * leg.baseAmount.abs();
        holdingBase = -cashBase;
      }
      // A line of nothing has no base amount.
      if (amount == 0) holdingBase = 0;
    }

    final holding = EntryLine(
      accountId: BookAccount.holdingId(t.instrumentID),
      amount: amount,
      currency: currency,
      baseAmount: holdingBase,
      quantity: direction == 0 ? null : _count(t.quantity, direction),
      commodity: t.instrumentID,
      unit: t.unit,
      karat: t.karat?.rawValue,
      // Adding zero turns a negative zero into zero, so it reads the same
      // whether or not the price is written.
      unitPrice: t.unitPrice != 0 || _carriesPrice(t.kind) ? t.unitPrice + 0.0 : null,
      fee: t.fee != 0 ? t.fee : null,
      quantityRaw: direction == 0 ? (t.quantity == 0 ? null : t.quantity) : _raw(t.quantity),
    );
    // A row that moves quantity and no money stands alone; otherwise the
    // cost is the other side of Holdings.
    final alone = amount == 0 && direction != 0 && leg == null;
    final lines = <EntryLine>[holding];
    if (leg != null) {
      lines.add(EntryLine(accountId: leg.accountId, amount: cashAmount, currency: leg.currency, baseAmount: cashBase));
      // One currency: whatever the cash and the cost do not agree on.
      final off = -(amount + cashAmount);
      if (leg.currency == currency && off != 0) {
        lines.add(EntryLine(accountId: SystemAccount.holdings.id, amount: off, currency: currency, baseAmount: currency == base ? off : 0));
      }
    } else if (!alone) {
      lines.add(EntryLine(accountId: SystemAccount.holdings.id, amount: -amount, currency: currency, baseAmount: -amount));
    }
    return BookEntry(id: t.id, date: t.date, template: _templates[t.kind]!, baseCurrency: base, lines: lines, merchant: merchant, note: t.note);
  }

  /// The line of [entry] on an account that is neither a holding nor a system
  /// account: where the money of a trade came from or went. Null when none.
  static EntryLine? cashLegOf(BookEntry entry) {
    for (final l in entry.lines) {
      if (l.accountId.startsWith('holding.') || _systemIds.contains(l.accountId)) continue;
      return l;
    }
    return null;
  }

  /// The cash that [trade] moved as the entry that stood for it before a
  /// trade was one entry: a `holding_trade` between the cash account and
  /// `system.holdings`, with the id of [holdingCashId]. Null when the trade
  /// moved no cash. Quantities, prices and the holding account are not part
  /// of it, nor is the trade's note.
  static BookEntry? cashHalf(BookEntry trade) {
    final cash = HoldingEntryCodec.cashLegOf(trade);
    if (cash == null) return null;
    return BookEntry(
      id: holdingCashId(trade.id),
      date: trade.date,
      postedDate: trade.postedDate,
      template: EntryTemplate.holdingTrade,
      status: trade.status,
      baseCurrency: trade.baseCurrency,
      lines: [
        EntryLine(accountId: cash.accountId, amount: cash.amount, currency: cash.currency, baseAmount: cash.baseAmount),
        EntryLine(accountId: SystemAccount.holdings.id, amount: -cash.amount, currency: cash.currency, baseAmount: -cash.baseAmount),
      ],
      merchant: trade.merchant,
      source: trade.source,
    );
  }

  static final Set<String> _systemIds = {for (final a in SystemAccount.values) a.id};

  static HoldingTransaction fromEntry(BookEntry entry) {
    final (t, why) = _read(entry);
    if (t == null) throw ArgumentError('Entry ${entry.id}: $why');
    return t;
  }

  /// As [fromEntry], or null when the entry cannot be read as a holding row:
  /// a record from elsewhere that lost the facts of its line.
  static HoldingTransaction? tryFromEntry(BookEntry entry) => _read(entry).$1;

  static (HoldingTransaction?, String?) _read(BookEntry entry) {
    final kind = _templates.entries.where((e) => e.value == entry.template).map((e) => e.key).firstOrNull;
    if (kind == null) return (null, '${entry.template.wireName} is not a holding entry.');
    final line = entry.lines.where((l) => l.commodity != null).firstOrNull;
    if (line == null) return (null, 'no line on a holding.');
    final unit = line.unit;
    if (unit == null) return (null, 'no unit.');

    final double quantity;
    if (line.quantityRaw != null) {
      quantity = line.quantityRaw!;
    } else if (line.quantity == null) {
      quantity = 0;
    } else {
      quantity = (kind.removes ? -line.quantity! : line.quantity!) / _scale;
    }

    return (
      HoldingTransaction(
        id: entry.id,
        instrumentID: line.commodity!,
        kind: kind,
        quantity: quantity,
        unit: unit,
        karat: line.karat == null ? null : GoldKarat.fromRawValue(line.karat!),
        unitPrice: line.unitPrice ?? 0,
        fee: line.fee ?? 0,
        currency: line.currency,
        date: entry.date,
        note: entry.note,
      ),
      null,
    );
  }

  /// [major] in minor units of [currency]; total. An amount no count can hold
  /// (beyond a 64-bit count, or not a number) is held at the nearest count
  /// that fits, and zero for not a number: the line's facts (`px`, `fee`,
  /// `qty`) carry the real figures, and the entry stays balanced.
  static int _minor(double major, String currency) {
    final scaled = major * math.pow(10, MinorUnits.digits(currency));
    if (scaled.isNaN) return 0;
    if (!scaled.isFinite || scaled.abs() >= _intLimit) return scaled < 0 ? -_intLimit.toInt() : _intLimit.toInt();
    return MinorUnits.fromMajor(major, currency);
  }

  /// Buys, sells and transfers in carry the price even when it is zero, so a
  /// line says what it was priced at; the others only when it is not.
  static bool _carriesPrice(TransactionKind kind) => kind == TransactionKind.buy || kind == TransactionKind.sell || kind == TransactionKind.transferIn;

  /// [quantity] as a signed count of 1e-8 of the unit, positive when
  /// [direction] is 1. Null when it does not fit a count.
  static int? _count(double quantity, int direction) {
    final scaled = quantity * _scale;
    if (!scaled.isFinite || scaled.abs() >= _intLimit) return null;
    return direction * scaled.round();
  }

  /// [quantity] itself when the count does not give it back exactly.
  static double? _raw(double quantity) {
    if (quantity == 0) return null;
    final scaled = quantity * _scale;
    if (scaled.isFinite && scaled.abs() < _exactLimit && scaled.round() / _scale == quantity) return null;
    return quantity;
  }
}
