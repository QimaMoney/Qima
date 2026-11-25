import 'package:flutter_test/flutter_test.dart';
import 'package:qima/l10n/app_localizations_ar.dart';
import 'package:qima/l10n/app_localizations_en.dart';
import 'package:qima/l10n/app_localizations_es.dart';
import 'package:qima/l10n/app_localizations_fr.dart';
import 'package:qima/models/book_entry.dart';
import 'package:qima/services/holdings_ledger.dart';
import 'package:qima/widgets/trade_failure.dart';

HoldingRejected _rejected(EntryProblem problem) => HoldingRejected([EntryIssue(problem, 'x', 'The line on holding.metal.XAU is zero.')]);

void main() {
  final en = AppLocalizationsEn();

  test('a trade with nothing in it, and one whose cash does not match, each have their own sentence', () {
    expect(tradeFailureText(en, _rejected(EntryProblem.zeroLine)), en.tradeRejectedNothing);
    for (final p in [EntryProblem.unbalanced, EntryProblem.baseMismatch, EntryProblem.baseSignMismatch, EntryProblem.wrongCurrency, EntryProblem.unknownAccount]) {
      expect(tradeFailureText(en, _rejected(p)), en.tradeRejectedCash, reason: p.name);
    }
    // Nothing is ever the developer's text.
    expect(tradeFailureText(en, _rejected(EntryProblem.zeroLine)), isNot(contains('holding.')));
  });

  test('anything else is the general sentence', () {
    expect(tradeFailureText(en, _rejected(EntryProblem.tooFewLines)), en.tradeSaveFailed);
    expect(tradeFailureText(en, StateError('x')), en.tradeSaveFailed);
    expect(tradeFailureText(en, ArgumentError('No rate for JPY.')), en.tradeSaveFailed);
    expect(tradeFailureText(en, const HoldingRejected([])), en.tradeSaveFailed);
  });

  test('every language has every sentence of this change, none left as the English one', () {
    for (final l in [AppLocalizationsAr(), AppLocalizationsEs(), AppLocalizationsFr()]) {
      final own = [
        l.tradeSaveFailed, l.tradeRejectedNothing, l.tradeRejectedCash, l.bookHealthMigration, l.bookHealthNewerBuild, l.bookHealthLegacy,
        l.bookHealthLoadFailed, l.backupErrorHoldingsUnreadable, l.settingsNeedsAttention, l.settingsICloudSyncStatusAttention, l.backupImportReplaceDropsCash(1), l.backupImportReplaceDropsCash(3),
      ];
      final english = [
        en.tradeSaveFailed, en.tradeRejectedNothing, en.tradeRejectedCash, en.bookHealthMigration, en.bookHealthNewerBuild, en.bookHealthLegacy,
        en.bookHealthLoadFailed, en.backupErrorHoldingsUnreadable, en.settingsNeedsAttention, en.settingsICloudSyncStatusAttention, en.backupImportReplaceDropsCash(1), en.backupImportReplaceDropsCash(3),
      ];
      for (var i = 0; i < own.length; i++) {
        expect(own[i], isNot(english[i]), reason: '${l.localeName} string $i');
        expect(own[i], isNotEmpty);
      }
    }
  });
}
