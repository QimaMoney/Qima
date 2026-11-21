import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qima/blocs/app_cubit.dart';
import 'package:qima/blocs/app_state.dart';
import 'package:qima/blocs/money_cubit.dart';
import 'package:qima/l10n/app_localizations.dart';
import 'package:qima/screens/settings_screen.dart';
import 'package:qima/services/ai_apps.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/preferences.dart';
import 'package:qima/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What Settings says about the book: one row for each kind of problem, with
/// what to do, and a sync status that is not "up to date" while one stands.
void main() {
  Future<AppCubit> show(WidgetTester tester, {required BookHealth health, CloudSyncStatus status = CloudSyncStatus.upToDate}) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('qima_book_health_settings'));
    addTearDown(() => dir!.deleteSync(recursive: true));
    LocalFileStore.overrideDirectoryForTesting(dir!);
    SharedPreferences.setMockInitialValues({});
    final app = AppCubit();
    app.preferences = await Preferences.create();
    app.emit(app.state.copyWith(initialized: true, iCloudSyncEnabled: true, cloudSyncStatus: status, lastCloudSyncAt: DateTime(2026, 11, 5, 14, 32), bookHealth: health));
    final money = MoneyCubit(store: app.bookStore, baseCurrency: () => app.state.baseCurrency, rates: () => app.state.rates);
    await tester.runAsync(money.load);
    final ai = (await tester.runAsync(() async => AiApps(app: app, money: money)))!;
    tester.view.physicalSize = const Size(390, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        RepositoryProvider<AiApps>.value(value: ai),
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<MoneyCubit>.value(value: money),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildTheme(Brightness.light),
        home: const SettingsScreen(),
      ),
    ));
    await tester.pumpAndSettle();
    return app;
  }

  Future<AppLocalizations> l10n() => AppLocalizations.delegate.load(const Locale('en'));

  testWidgets('a book with nothing wrong shows no problem rows', (tester) async {
    try {
      await show(tester, health: BookHealth.fine);
      final strings = await l10n();
      expect(find.text(strings.settingsNeedsAttention.toUpperCase()), findsNothing);
      expect(find.text(strings.bookHealthMigration), findsNothing);
      expect(find.textContaining(strings.settingsICloudSyncStatusUpToDate('14:32')), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('every kind of problem has its own row, and sync does not say up to date', (tester) async {
    try {
      final app = await show(
        tester,
        health: const BookHealth(migrationFailed: true, legacyUnreadable: true, newerVersion: true, loadFailed: true),
        status: CloudSyncStatus.needsAttention,
      );
      final strings = await l10n();
      expect(find.text(strings.settingsNeedsAttention.toUpperCase()), findsOneWidget);
      for (final (key, text) in [
        ('bookHealthMigration', strings.bookHealthMigration),
        ('bookHealthNewerBuild', strings.bookHealthNewerBuild),
        ('bookHealthLegacy', strings.bookHealthLegacy),
        ('bookHealthLoadFailed', strings.bookHealthLoadFailed),
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
        expect(find.text(text), findsOneWidget, reason: key);
      }
      expect(find.text(strings.bookHealthNewerBuild), findsOneWidget);
      expect(find.textContaining('Update Qima on this device'), findsOneWidget);
      expect(find.text(strings.settingsICloudSyncStatusAttention), findsOneWidget);
      expect(find.textContaining(strings.settingsICloudSyncStatusUpToDate('14:32')), findsNothing);

      // One kind alone shows only its row, and the row goes when the problem does.
      app.emit(app.state.copyWith(bookHealth: const BookHealth(newerVersion: true)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bookHealthNewerBuild')), findsOneWidget);
      expect(find.byKey(const ValueKey('bookHealthMigration')), findsNothing);
      app.emit(app.state.copyWith(bookHealth: BookHealth.fine, cloudSyncStatus: CloudSyncStatus.upToDate));
      await tester.pumpAndSettle();
      expect(find.text(strings.settingsNeedsAttention.toUpperCase()), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
