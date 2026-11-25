import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qima/blocs/app_blocs.dart';
import 'package:qima/blocs/cloud_log_sync.dart';
import 'package:qima/blocs/cloud_log_sync_state.dart';
import 'package:qima/blocs/money_cubit.dart';
import 'package:qima/l10n/app_localizations.dart';
import 'package:qima/screens/settings_screen.dart';
import 'package:qima/services/ai_apps.dart';
import 'package:qima/services/book_store.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/preferences.dart';
import 'package:qima/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/app_blocs.dart';
import '../services/sync/memory_sync_transport.dart';

/// The row under the iCloud switch that turns on the CloudKit change log
/// sync: offered only where it can be used and while iCloud sync is on, off
/// until turned on, and one line of status under it.
void main() {
  late Preferences preferences;

  Future<AppBlocs> show(WidgetTester tester, {required bool available, bool iCloudOn = true}) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('qima_cloud_log_settings'));
    addTearDown(() => dir!.deleteSync(recursive: true));
    LocalFileStore.overrideDirectoryForTesting(dir!);
    SharedPreferences.setMockInitialValues({});
    preferences = await Preferences.create();
    final book = BookStore();
    final cloudLog = CloudLogSync(
      store: book,
      transport: MemorySyncTransport(),
      available: () async => available,
      account: () async => 'account-one',
      reload: () async {},
    );
    final app = AppBlocs(bookStore: book, cloudLog: cloudLog);
    app.settings.preferences = preferences;
    await tester.runAsync(() => cloudLog.start(preferences));
    app.seed(initialized: true, iCloudSyncEnabled: iCloudOn);
    final money = MoneyCubit(store: book, baseCurrency: () => app.settings.state.baseCurrency, rates: () => app.market.state.rates);
    await tester.runAsync(money.load);
    final ai = (await tester.runAsync(() async => AiApps(app: app.app, settings: app.settings, market: app.market, holdings: app.holdings, money: money)))!;
    tester.view.physicalSize = const Size(390, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        RepositoryProvider<AiApps>.value(value: ai),
        ...app.providers,
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

  final switchRow = find.byKey(const ValueKey('cloudLogSyncSwitch'));

  testWidgets('it is not offered where CloudKit cannot be used', (tester) async {
    try {
      await show(tester, available: false);
      expect(find.text((await l10n()).settingsICloudSyncSwitch), findsOneWidget);
      expect(switchRow, findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('it is not offered while iCloud sync is off', (tester) async {
    try {
      await show(tester, available: true, iCloudOn: false);
      expect(switchRow, findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('it is offered, off, and turning it on sets the preference of this device and shows the status', (tester) async {
    try {
      final app = await show(tester, available: true);
      final strings = await l10n();
      expect(switchRow, findsOneWidget);
      expect(find.text(strings.settingsCloudLogSyncSwitch), findsOneWidget);
      expect(find.text(strings.settingsCloudLogSyncFooter), findsOneWidget);
      expect(tester.widget<SwitchListTile>(switchRow).value, isFalse);
      expect(preferences.cloudLogSyncEnabled, isFalse);
      expect(find.byKey(const ValueKey('cloudLogSyncStatus')), findsNothing);

      await tester.tap(switchRow);
      await tester.pumpAndSettle();
      expect(preferences.cloudLogSyncEnabled, isTrue);
      expect(tester.widget<SwitchListTile>(switchRow).value, isTrue);
      expect(app.cloudLog.state.enabled, isTrue);
      expect(find.text(strings.settingsCloudLogSyncStatusSyncing), findsOneWidget);

      await tester.tap(switchRow);
      await tester.pumpAndSettle();
      expect(preferences.cloudLogSyncEnabled, isFalse);
      expect(tester.widget<SwitchListTile>(switchRow).value, isFalse);
      expect(find.byKey(const ValueKey('cloudLogSyncStatus')), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the status line says up to date at a time, waiting, and every problem in words', (tester) async {
    try {
      final app = await show(tester, available: true);
      final strings = await l10n();
      Future<void> shows(CloudLogSyncState state, String text) async {
        app.seed(cloudLogSync: state);
        await tester.pumpAndSettle();
        expect(find.descendant(of: find.byKey(const ValueKey('cloudLogSyncStatus')), matching: find.text(text)), findsOneWidget, reason: '$state');
      }

      await shows(CloudLogSyncState(phase: CloudLogPhase.upToDate, at: DateTime(2026, 11, 5, 14, 32)), strings.settingsCloudLogSyncStatusUpToDate('14:32'));
      await shows(const CloudLogSyncState(phase: CloudLogPhase.waiting), strings.settingsCloudLogSyncStatusWaiting);
      for (final (problem, text) in [
        (CloudLogProblem.quota, strings.settingsCloudLogSyncStatusQuota),
        (CloudLogProblem.notSignedIn, strings.settingsCloudLogSyncStatusNotSignedIn),
        (CloudLogProblem.unavailable, strings.settingsCloudLogSyncStatusUnavailable),
        (CloudLogProblem.zoneMissing, strings.settingsCloudLogSyncStatusZoneMissing),
        (CloudLogProblem.newerVersion, strings.settingsCloudLogSyncStatusNewerVersion),
        (CloudLogProblem.offline, strings.settingsCloudLogSyncStatusOffline),
        (CloudLogProblem.other, strings.settingsCloudLogSyncStatusOther),
      ]) {
        await shows(CloudLogSyncState(phase: CloudLogPhase.problem, problem: problem), text);
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('only the row rebuilds when the status changes, not the iCloud switch above it', (tester) async {
    try {
      final app = await show(tester, available: true);
      final before = tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, (await l10n()).settingsICloudSyncSwitch));
      app.seed(cloudLogSync: const CloudLogSyncState(phase: CloudLogPhase.waiting));
      await tester.pumpAndSettle();
      final after = tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, (await l10n()).settingsICloudSyncSwitch));
      expect(identical(before, after), isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the longest status fits a narrow screen without overflow', (tester) async {
    try {
      final app = await show(tester, available: true);
      app.seed(cloudLogSync: const CloudLogSyncState(phase: CloudLogPhase.problem, problem: CloudLogProblem.zoneMissing));
      tester.view.physicalSize = const Size(360, 3600);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
