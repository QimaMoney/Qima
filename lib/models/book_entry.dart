import 'package:equatable/equatable.dart';

import 'asset.dart';
import 'book_account.dart';
import 'syncable.dart';

/// The named ways an entry is made. Lists and filters show the template's
/// name ("Card payment", "Lent"); what counts as spending is decided by the
/// lines, never by the template.
enum EntryTemplate {
  opening('opening'),
  spend('spend'),
  income('income'),
  transfer('transfer'),
  atm('atm'),
  swap('swap'),
  cardPayment('card_payment'),
  loanPayment('loan_payment'),
  lent('lent'),
  borrowed('borrowed'),
  repaymentIn('repayment_in'),
  repaymentOut('repayment_out'),
  refund('refund'),
  declined('declined'),
  cashCount('cash_count'),
  billSplit('bill_split'),
  valuation('valuation'),
  assetSale('asset_sale'),

  /// The cash side of a holdings trade as the two-record form of an earlier
  /// build kept it: money between a cash account and Holdings, with the trade
  /// as a record of its own. A trade is now one entry of a holding template
  /// ([isHoldingEntry]); this template remains on cash entries that were not
  /// folded into a trade, and they stay money entries.
  holdingTrade('holding_trade'),

  /// A holding changing hands, line for line as a `HoldingTransaction`: the
  /// quantity moves on the holding's own line and the cost on Holdings.
  holdingBuy('holding_buy'),
  holdingSell('holding_sell'),
  holdingIn('holding_in'),
  holdingOut('holding_out'),
  holdingFee('holding_fee'),
  adjustment('adjustment');

  /// The stored name, as in design.md section 7.
  final String wireName;

  const EntryTemplate(this.wireName);

  /// One of the five templates of a holding changing hands. They belong to
  /// the holdings ledger, not to money lists and filters.
  bool get isHoldingEntry => this == holdingBuy || this == holdingSell || this == holdingIn || this == holdingOut || this == holdingFee;

  static EntryTemplate fromWire(String? name) =>
      EntryTemplate.values.firstWhere((t) => t.wireName == name, orElse: () => EntryTemplate.adjustment);
}

enum EntryStatus {
  pending,
  posted,

  /// Shown struck through; never in a balance.
  declined;

  static EntryStatus fromName(String? name) =>
      EntryStatus.values.firstWhere((s) => s.name == name, orElse: () => EntryStatus.posted);
}

/// How an entry came into the books.
enum EntrySource {
  typed,
  voice,
  import,
  count,
  rule,
  valuation,
  migration;

  static EntrySource fromName(String? name) =>
      EntrySource.values.firstWhere((s) => s.name == name, orElse: () => EntrySource.typed);
}

/// One line of an entry: an amount posted to one account, and for a holding
/// the quantity that moved with it.
///
/// The fields after [baseAmount] are the facts of a holding movement. They
/// are left out of the JSON when null, so a money line writes exactly the
/// four keys it always has.
class EntryLine extends Equatable {
  final String accountId;

  /// Whole minor units of [currency], debit-positive (see `AccountSide`).
  final int amount;
  final String currency;

  /// The same amount in minor units of the entry's base currency, at the
  /// rate the entry was made with. Equal to [amount] when [currency] is the
  /// base. Lets an entry that changes currency balance in one unit.
  final int baseAmount;

  /// A signed count of 1e-8 of [unit] (positive is in), for a line on a
  /// holding account.
  final int? quantity;

  /// The instrument the [quantity] is of, such as `metal.XAU`.
  final String? commodity;
  final PriceUnit? unit;

  /// Purity of gold counted by weight, as `GoldKarat.rawValue`.
  final int? karat;

  /// Per [unit], in [currency].
  final double? unitPrice;

  /// The commission or charge of the movement, in [currency].
  final double? fee;

  /// The quantity in [unit] as entered, kept only when it is not exactly
  /// [quantity] / 1e-8, so the original number comes back bit for bit.
  final double? quantityRaw;

  const EntryLine({
    required this.accountId,
    required this.amount,
    required this.currency,
    required this.baseAmount,
    this.quantity,
    this.commodity,
    this.unit,
    this.karat,
    this.unitPrice,
    this.fee,
    this.quantityRaw,
  });

  /// This line posted to [accountId] instead, with everything else kept.
  EntryLine withAccount(String accountId) => EntryLine(
        accountId: accountId,
        amount: amount,
        currency: currency,
        baseAmount: baseAmount,
        quantity: quantity,
        commodity: commodity,
        unit: unit,
        karat: karat,
        unitPrice: unitPrice,
        fee: fee,
        quantityRaw: quantityRaw,
      );

  /// Whether the line carries any fact of a holding movement.
  bool get hasHoldingFacts => quantity != null || commodity != null || quantityRaw != null;

  /// A line that carries a commodity and sits on that commodity's holding
  /// account. Only such a line may carry a quantity.
  bool get isHoldingLine => commodity != null && accountId == BookAccount.holdingId(commodity!);

  /// A holding line that moves a quantity, however small: a count of 1e-8
  /// that rounds to zero still moves its [quantityRaw].
  bool get movesQuantity => isHoldingLine && ((quantity ?? 0) != 0 || (quantityRaw ?? 0) != 0);

  /// A line that moves a quantity and no money.
  bool get isQuantityOnly => amount == 0 && movesQuantity;

  Map<String, dynamic> toJson() => {
        'account': accountId,
        'amount': amount,
        'currency': currency,
        'base': baseAmount,
        if (quantity != null) 'qty': quantity,
        if (commodity != null) 'commodity': commodity,
        if (unit != null) 'unit': unit!.name,
        if (karat != null) 'karat': karat,
        if (unitPrice != null) 'px': unitPrice,
        if (fee != null) 'fee': fee,
        if (quantityRaw != null) 'qtyRaw': quantityRaw,
      };

  /// Reads the holding keys the way every other enum and optional field is
  /// read: what this build does not understand is left out, not thrown on, so
  /// one line from a later build cannot make a whole collection unreadable.
  /// An unknown `unit` or a `qty` that is not a whole number reads as null; a
  /// store keeps the row it was given until the entry is saved again, and a
  /// line without a unit or count is skipped by the holdings ledger
  /// (`HoldingEntryCodec.tryFromEntry`).
  factory EntryLine.fromJson(Map<String, dynamic> json) => EntryLine(
        accountId: json['account'] as String,
        amount: json['amount'] as int,
        currency: json['currency'] as String,
        baseAmount: json['base'] as int,
        quantity: _wholeNumber(json['qty']),
        commodity: json['commodity'] is String ? json['commodity'] as String : null,
        unit: PriceUnit.values.where((u) => u.name == json['unit']).firstOrNull,
        karat: _wholeNumber(json['karat']),
        unitPrice: (json['px'] as num?)?.toDouble(),
        fee: (json['fee'] as num?)?.toDouble(),
        quantityRaw: (json['qtyRaw'] as num?)?.toDouble(),
      );

  /// [value] when it is a whole number (`2.0` counts), else null.
  static int? _wholeNumber(Object? value) {
    if (value is int) return value;
    if (value is double && value.isFinite && value == value.truncateToDouble() && value.abs() < 9.2e18) return value.toInt();
    return null;
  }

  @override
  List<Object?> get props => [accountId, amount, currency, baseAmount, quantity, commodity, unit, karat, unitPrice, fee, quantityRaw];
}

/// Why an entry, or an account it uses, can't go into the books.
enum EntryProblem {
  tooFewLines,
  zeroLine,
  baseSignMismatch,
  baseMismatch,
  unbalanced,
  unknownAccount,
  wrongCurrency,
  badAccount,

  /// A line carries holding facts (a quantity, a commodity) but is not on
  /// the holding account of its commodity.
  badHoldingLine,
}

class EntryIssue extends Equatable {
  final EntryProblem problem;

  /// The entry, or for [EntryProblem.badAccount] the account.
  final String id;
  final String detail;

  const EntryIssue(this.problem, this.id, this.detail);

  @override
  String toString() => '${problem.name} ($id): $detail';

  @override
  List<Object?> get props => [problem, id, detail];
}

/// Which versions of the two old records (the holdings row and its cash
/// entry) an entry was made from, by their `updatedAt`. A half that did not
/// exist when the entry was made is null. A tombstoned half still counts:
/// its stamp is a version too.
///
/// Stored as `{"t": <stamp>, "c": <stamp>}`, a key left out for an absent
/// half. See `LegacyCollapse`.
class LegacyProvenance extends Equatable {
  /// The holdings row's `updatedAt`, in UTC.
  final DateTime? trade;

  /// The cash entry's `updatedAt`, in UTC.
  final DateTime? cash;

  LegacyProvenance({DateTime? trade, DateTime? cash})
      : trade = trade?.toUtc(),
        cash = cash?.toUtc();

  Map<String, dynamic> toJson() => {
        if (trade != null) 't': trade!.toIso8601String(),
        if (cash != null) 'c': cash!.toIso8601String(),
      };

  /// Null when [json] is not a map or names no stamp this build can read.
  static LegacyProvenance? fromJson(Object? json) {
    if (json is! Map) return null;
    final t = json['t'] is String ? DateTime.tryParse(json['t'] as String) : null;
    final c = json['c'] is String ? DateTime.tryParse(json['c'] as String) : null;
    return t == null && c == null ? null : LegacyProvenance(trade: t, cash: c);
  }

  @override
  List<Object?> get props => [trade?.microsecondsSinceEpoch, cash?.microsecondsSinceEpoch];
}

/// One event in the books: two or more lines that balance. Shown to people
/// as a transaction. An entry and its lines sync as one record, so a device
/// never sees half an entry.
class BookEntry extends Equatable implements Syncable {
  @override
  final String id;
  final DateTime date;

  /// When the bank posted it, if later than [date].
  final DateTime? postedDate;
  final EntryTemplate template;
  final EntryStatus status;

  /// The currency [EntryLine.baseAmount] is in. Kept on the entry so a
  /// change of the person's base currency never unbalances old entries.
  final String baseCurrency;
  final List<EntryLine> lines;
  final String merchant;

  /// The text as it arrived (an SMS, a statement row), before merchant rules.
  final String rawMerchant;
  final String note;
  final EntrySource source;

  /// Set only on an entry made from the old two-record form of a holdings
  /// trade; left out of the JSON when null.
  final LegacyProvenance? legacy;

  const BookEntry({
    required this.id,
    required this.date,
    required this.template,
    required this.baseCurrency,
    required this.lines,
    this.postedDate,
    this.status = EntryStatus.posted,
    this.merchant = '',
    this.rawMerchant = '',
    this.note = '',
    this.source = EntrySource.typed,
    this.legacy,
  });

  /// Pending and posted entries move balances; a declined one doesn't.
  bool get counts => status != EntryStatus.declined;

  Set<String> get currencies => {for (final l in lines) l.currency};

  /// Whatever is wrong with the entry on its own, before looking at the
  /// accounts. Empty means it balances.
  ///
  /// The rule: lines in one currency must sum to zero in that currency.
  /// Lines in several currencies must sum to zero in the base currency
  /// (an FX difference is closed with a Rounding line, see `EntryBuilder`).
  List<EntryIssue> get issues {
    final out = <EntryIssue>[];
    if (lines.isEmpty && status == EntryStatus.declined) return out;
    // A movement of quantity with no money (a holding transferred out) is one
    // line, and only a line on a holding may move a quantity.
    final quantityOnly = lines.length == 1 && lines.single.isQuantityOnly;
    if (lines.length < 2 && !quantityOnly) out.add(EntryIssue(EntryProblem.tooFewLines, id, 'An entry needs two lines or more; it has ${lines.length}.'));
    for (final l in lines) {
      if (l.amount == 0 && !l.movesQuantity) out.add(EntryIssue(EntryProblem.zeroLine, id, 'The line on ${l.accountId} is zero.'));
      if (l.hasHoldingFacts && !l.isHoldingLine) {
        out.add(EntryIssue(EntryProblem.badHoldingLine, id, 'The line on ${l.accountId} carries a quantity or commodity but is not on the holding of its commodity.'));
      }
      if (l.currency == baseCurrency && l.baseAmount != l.amount) {
        out.add(EntryIssue(EntryProblem.baseMismatch, id, 'The line on ${l.accountId} is in the base currency, so its base amount must equal it.'));
      } else if (l.baseAmount != 0 && l.baseAmount.sign != l.amount.sign) {
        out.add(EntryIssue(EntryProblem.baseSignMismatch, id, 'The line on ${l.accountId} changes sign in the base currency.'));
      }
    }
    final ccys = currencies;
    if (ccys.length == 1) {
      final sum = lines.fold<int>(0, (a, l) => a + l.amount);
      if (sum != 0) out.add(EntryIssue(EntryProblem.unbalanced, id, 'The lines are off by $sum in ${ccys.first}.'));
    } else if (ccys.length > 1) {
      final sum = lines.fold<int>(0, (a, l) => a + l.baseAmount);
      if (sum != 0) out.add(EntryIssue(EntryProblem.unbalanced, id, 'The lines are off by $sum in $baseCurrency.'));
    }
    return out;
  }

  bool get isBalanced => issues.isEmpty;

  BookEntry copyWith({DateTime? date, DateTime? postedDate, EntryStatus? status, List<EntryLine>? lines, String? merchant, String? note, String? rawMerchant, EntrySource? source, LegacyProvenance? legacy}) =>
      BookEntry(
        id: id,
        date: date ?? this.date,
        postedDate: postedDate ?? this.postedDate,
        template: template,
        status: status ?? this.status,
        baseCurrency: baseCurrency,
        lines: lines ?? this.lines,
        merchant: merchant ?? this.merchant,
        rawMerchant: rawMerchant ?? this.rawMerchant,
        note: note ?? this.note,
        source: source ?? this.source,
        legacy: legacy ?? this.legacy,
      );

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.toUtc().toIso8601String(),
        if (postedDate != null) 'postedDate': postedDate!.toUtc().toIso8601String(),
        'template': template.wireName,
        if (status != EntryStatus.posted) 'status': status.name,
        'base': baseCurrency,
        'lines': [for (final l in lines) l.toJson()],
        if (merchant.isNotEmpty) 'merchant': merchant,
        if (rawMerchant.isNotEmpty) 'rawMerchant': rawMerchant,
        if (note.isNotEmpty) 'note': note,
        if (source != EntrySource.typed) 'source': source.name,
        if (legacy != null) 'legacy': legacy!.toJson(),
      };

  factory BookEntry.fromJson(Map<String, dynamic> json) => BookEntry(
        id: json['id'] as String,
        // Stored as a UTC instant, read back in local time so the calendar
        // day shown is the one the person picked (as HoldingTransaction).
        date: DateTime.parse(json['date'] as String).toLocal(),
        postedDate: json['postedDate'] == null ? null : DateTime.parse(json['postedDate'] as String).toLocal(),
        template: EntryTemplate.fromWire(json['template'] as String?),
        status: EntryStatus.fromName(json['status'] as String?),
        baseCurrency: json['base'] as String,
        lines: [for (final l in json['lines'] as List) EntryLine.fromJson((l as Map).cast<String, dynamic>())],
        merchant: json['merchant'] as String? ?? '',
        rawMerchant: json['rawMerchant'] as String? ?? '',
        note: json['note'] as String? ?? '',
        source: EntrySource.fromName(json['source'] as String?),
        legacy: LegacyProvenance.fromJson(json['legacy']),
      );

  @override
  List<Object?> get props => [id, date, postedDate, template, status, baseCurrency, lines, merchant, rawMerchant, note, source, legacy];
}
