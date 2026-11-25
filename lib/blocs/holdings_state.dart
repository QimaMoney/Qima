import 'package:equatable/equatable.dart';

import '../models/holding.dart';
import '../models/holding_transaction.dart';
import '../models/ledger.dart';

/// The holdings ledger (v3): every trade, the source of truth for everything
/// held.
class HoldingsState extends Equatable {
  final List<HoldingTransaction> transactions;

  /// Positions derived from [transactions]; re-derived only when they
  /// change, never on a price tick.
  final Ledger ledger;

  HoldingsState({
    List<HoldingTransaction>? transactions,
    // Shorthand for a ledger of plain buys, one per lot.
    List<HoldingLot>? lots,
    Ledger? ledger,
  })  : transactions = transactions ?? _buys(lots),
        ledger = ledger ?? Ledger.derive(transactions ?? _buys(lots));

  static List<HoldingTransaction> _buys(List<HoldingLot>? lots) =>
      lots == null ? const [] : [for (final lot in lots) HoldingTransaction.fromLot(lot)];

  /// What's held now, as lots — every acquisition scaled down by the
  /// disposals after it (see [Ledger]). Everything that values holdings
  /// reads this.
  List<HoldingLot> get lots => ledger.openLots;

  HoldingsState copyWith({
    List<HoldingTransaction>? transactions,
    // Shorthand for a ledger of plain buys, one per lot.
    List<HoldingLot>? lots,
  }) {
    final nextTransactions = transactions ?? (lots == null ? null : _buys(lots));
    return HoldingsState(
      transactions: nextTransactions ?? this.transactions,
      ledger: nextTransactions == null ? ledger : null,
    );
  }

  @override
  List<Object?> get props => [transactions];
}
