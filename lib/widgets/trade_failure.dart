import '../l10n/app_localizations.dart';
import '../models/book_entry.dart';
import '../services/holdings_ledger.dart';

/// What to tell the person when saving a trade (or a file of them) failed
/// and nothing was written. A rejected trade is named by what is wrong with
/// it; anything else (a rate that is missing, a record that cannot be
/// replaced, a store that could not be written) is the general sentence.
String tradeFailureText(AppLocalizations l10n, Object error) {
  if (error is HoldingRejected) {
    final problems = {for (final i in error.issues) i.problem};
    if (problems.contains(EntryProblem.zeroLine)) return l10n.tradeRejectedNothing;
    if (problems.any(_cash.contains)) return l10n.tradeRejectedCash;
  }
  return l10n.tradeSaveFailed;
}

/// The problems of the money side of a trade: the cash and the cost that do
/// not agree, in one currency or in the base one.
const _cash = {
  EntryProblem.unbalanced,
  EntryProblem.baseMismatch,
  EntryProblem.baseSignMismatch,
  EntryProblem.wrongCurrency,
  EntryProblem.unknownAccount,
};
