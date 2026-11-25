import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qima/blocs/app_blocs.dart';
import 'package:qima/l10n/app_localizations.dart';
import 'package:qima/models/asset.dart';
import 'package:qima/models/fx_history.dart';
import 'package:qima/models/quote.dart';
import 'package:qima/services/local_file_store.dart';
import 'package:qima/services/notification_service.dart';
import 'package:qima/services/preferences.dart';
import 'package:qima/services/price_repository.dart';
import 'package:qima/theme/app_theme.dart';
import 'package:qima/widgets/lock_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/app_blocs.dart';

class _NoopRepository extends PriceRepository {
  @override
  Future<Map<String, QuoteSeries>> refreshAll(List<Instrument> instruments, {DateTime? now}) async => {};

  @override
  Future<FXHistory> backfillFXHistory(List<String> currencies, {bool force = false, DateTime? now}) async => FXHistory.empty;

  @override
  Future<Map<String, QuoteSeries>> backfillInstruments(List<Instrument> instruments, FXHistory fxHistory,
          {bool force = false, DateTime? now}) async =>
      {};
}

class _QuietNotifications extends NotificationService {
  @override
  Future<void> init() async {}

  @override
  Future<bool> isEnabled() async => true;
}

/// The gate is mounted before start-up runs, as in the app (it sits in
/// `MaterialApp.builder`), so what the settings hold arrives after its first
/// build. Tests that seed the cubits before mounting never see that order.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const privacyChannel = MethodChannel('com.devlabtechnologies.qima/privacy');

  late List<bool> secureCalls;

  setUp(() {
    secureCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(privacyChannel, (call) async {
      if (call.method == 'setSecure') secureCalls.add((call.arguments as Map)['secure'] as bool);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(privacyChannel, null);
  });

  testWidgets('hide balances stored, app lock off: covers when inactive and marks the screen secure after a real start-up', (tester) async {
    // Android is where the secure flag exists.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.runAsync(() async {
      LocalFileStore.overrideDirectoryForTesting(await Directory.systemTemp.createTemp('qima_lock_gate_start_up'));
      SharedPreferences.setMockInitialValues({});
      final preferences = await Preferences.create();
      await preferences.setHideBalances(true);
    });

    final blocs = AppBlocs(repository: _NoopRepository(), notificationService: _QuietNotifications());
    await tester.pumpWidget(MultiBlocProvider(
      providers: blocs.providers,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildTheme(Brightness.light),
        home: const LockGate(child: Scaffold(body: Text('Real content'))),
      ),
    ));
    // Start-up, with the gate already on screen.
    await tester.runAsync(blocs.init);
    await tester.pump();
    expect(blocs.settings.state.hideBalances, isTrue);
    expect(blocs.settings.state.appLockEnabled, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();

    expect(find.byWidgetPredicate((w) => w.runtimeType.toString() == '_PrivacyCover'), findsOneWidget);
    expect(secureCalls, isNotEmpty);
    expect(secureCalls.last, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byWidgetPredicate((w) => w.runtimeType.toString() == '_PrivacyCover'), findsNothing);

    // A setting the gate does not read leaves the secure flag alone.
    final callsBefore = secureCalls.length;
    blocs.seed(appearance: Appearance.dark);
    await tester.pump();
    expect(secureCalls.length, callsBefore);

    // Turned off later, the cover and the secure flag follow it.
    await tester.runAsync(() => blocs.settings.setHideBalances(false));
    await tester.pump();
    expect(secureCalls.last, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.byWidgetPredicate((w) => w.runtimeType.toString() == '_PrivacyCover'), findsNothing);

    await tester.runAsync(blocs.close);
    // The framework checks this before tearDown runs.
    debugDefaultTargetPlatformOverride = null;
  });
}
