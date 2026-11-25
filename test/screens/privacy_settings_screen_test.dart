import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qima/blocs/app_blocs.dart';
import 'package:qima/l10n/app_localizations.dart';
import 'package:qima/screens/settings_screen.dart';
import 'package:qima/services/app_lock_service.dart';
import 'package:qima/services/preferences.dart';
import 'package:qima/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/app_blocs.dart';
import '../helpers/money_provider.dart';

/// Scriptable fake so these tests never touch real biometric hardware.
class _FakeAppLockService extends AppLockService {
  bool nextAuthResult = true;

  @override
  Future<bool> get isSupported async => true;

  @override
  Future<bool> authenticate({required String reason}) async => nextAuthResult;
}

void main() {
  Widget harness({required AppBlocs blocs}) {
    return MultiBlocProvider(providers: [...blocs.providers, testMoneyProvider(blocs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildTheme(Brightness.dark),
        home: const SettingsScreen(),
      ),
    );
  }

  testWidgets('tapping the Hide balances switch toggles SettingsCubit.state.hideBalances', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final blocs = AppBlocs(appLockService: _FakeAppLockService());
    blocs.settings.preferences = await Preferences.create();
    blocs.seed(initialized: true);

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.pumpWidget(harness(blocs: blocs));
    await tester.pumpAndSettle();

    expect(blocs.settings.state.hideBalances, isFalse);
    await tester.tap(find.widgetWithText(SwitchListTile, l10n.settingsHideBalances));
    await tester.pumpAndSettle();

    expect(blocs.settings.state.hideBalances, isTrue);
  });

  testWidgets('tapping the App lock switch on prompts authentication and enables it on success', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final lockService = _FakeAppLockService()..nextAuthResult = true;
    final blocs = AppBlocs(appLockService: lockService);
    blocs.settings.preferences = await Preferences.create();
    blocs.seed(initialized: true);

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.pumpWidget(harness(blocs: blocs));
    await tester.pumpAndSettle();

    expect(blocs.settings.state.appLockEnabled, isFalse);
    final appLockSwitch = find.widgetWithText(SwitchListTile, l10n.settingsAppLock);
    await tester.ensureVisible(appLockSwitch);
    await tester.pumpAndSettle();
    await tester.tap(appLockSwitch);
    await tester.pumpAndSettle();

    expect(blocs.settings.state.appLockEnabled, isTrue);
    final tile = tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, l10n.settingsAppLock));
    expect(tile.value, isTrue);
    // The "Lock after" row only appears once app lock is on.
    expect(find.text(l10n.settingsLockAfter), findsOneWidget);
  });

  testWidgets('a failed authentication leaves the App lock switch off and shows a snackbar', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final lockService = _FakeAppLockService()..nextAuthResult = false;
    final blocs = AppBlocs(appLockService: lockService);
    blocs.settings.preferences = await Preferences.create();
    blocs.seed(initialized: true);

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.pumpWidget(harness(blocs: blocs));
    await tester.pumpAndSettle();

    final appLockSwitch = find.widgetWithText(SwitchListTile, l10n.settingsAppLock);
    await tester.ensureVisible(appLockSwitch);
    await tester.pumpAndSettle();
    await tester.tap(appLockSwitch);
    await tester.pumpAndSettle();

    expect(blocs.settings.state.appLockEnabled, isFalse);
    expect(find.text(l10n.settingsAppLockFailed), findsOneWidget);
  });
}
