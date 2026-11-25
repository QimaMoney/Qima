import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'blocs/app_blocs.dart';
import 'blocs/app_cubit.dart';
import 'blocs/app_state.dart';
import 'blocs/import_cubit.dart';
import 'blocs/money_cubit.dart';
import 'blocs/settings_cubit.dart';
import 'blocs/settings_state.dart';
import 'l10n/app_localizations.dart';
import 'models/watch_card.dart';
import 'screens/backup_screen.dart';
import 'screens/home_shell.dart';
import 'screens/instrument_detail_screen.dart';
import 'screens/watch_watchlist_screen.dart';
import 'screens/zakat_screen.dart';
import 'screens/setup_flow_screen.dart';
import 'services/ai_apps.dart';
import 'services/import/import_inbox.dart';
import 'services/import/statement_files.dart';
import 'services/backup/backup_reminder_notifier.dart';
import 'services/notification_service.dart';
import 'services/planned_reminders.dart';
import 'screens/money/more_money_screens.dart';
import 'services/preferences.dart';
import 'services/zakat_reminder_notifier.dart';
import 'theme/app_theme.dart';
import 'widgets/lock_gate.dart';

/// Wear OS screens are typically 192-227dp square/round; a normal phone's
/// shortest side is comfortably larger than this, so a simple threshold is
/// enough to distinguish a watch form factor without any Wear-specific
/// package or platform channel.
const double _kWatchShortestSideThreshold = 250;

bool isWatchFormFactor(BuildContext context) =>
    MediaQuery.of(context).size.shortestSide < _kWatchShortestSideThreshold;

void main() {
  // `cryptography_flutter`'s plugin auto-registers with `package:cryptography`
  // (used by the Phase 6 backup encryption) as soon as it's a dependency —
  // no explicit enable call needed — routing AES-GCM/PBKDF2 through native OS
  // APIs on Android/iOS/macOS, which are dramatically faster than the
  // pure-Dart fallback. See `BackupCrypto`/`backup_crypto.dart`.
  LicenseRegistry.addLicense(_bundledFontLicenses);
  runApp(const QimaApp());
}

/// Surfaces the bundled fonts' licenses on the system licenses page, as the
/// SIL OFL requires the license to travel with the font.
Stream<LicenseEntry> _bundledFontLicenses() async* {
  yield LicenseEntryWithLineBreaks(
    const ['Almarai'],
    await rootBundle.loadString('assets/fonts/almarai/OFL.txt'),
  );
  yield LicenseEntryWithLineBreaks(
    const ['Riyal'],
    await rootBundle.loadString('assets/fonts/riyal/LICENSE'),
  );
}

class QimaApp extends StatefulWidget {
  const QimaApp({super.key});

  @override
  State<QimaApp> createState() => _QimaAppState();
}

class _QimaAppState extends State<QimaApp> with WidgetsBindingObserver {
  /// Lets notification-tap navigation reach the `Navigator` without a
  /// `BuildContext` from inside the tap-payload stream listener (spec Phase
  /// 5 "notification-tap navigation"). Pushing through this key still lands
  /// inside `MaterialApp`'s navigator, so `LockGate` — which wraps
  /// `builder`'s output ABOVE this navigator — still visually gates the
  /// pushed screen behind the lock screen/privacy cover until unlocked; nothing
  /// here bypasses it.
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late final AppBlocs _blocs;
  late final MoneyCubit _money;
  late final ImportCubit _import;
  late final AiApps _aiApps;
  StreamSubscription<String>? _tapSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _blocs = AppBlocs();
    _money = MoneyCubit(
      store: _blocs.sync.bookStore,
      baseCurrency: () => _blocs.settings.state.baseCurrency,
      rates: () => _blocs.market.state.rates,
    );
    _aiApps = AiApps(app: _blocs.app, settings: _blocs.settings, market: _blocs.market, holdings: _blocs.holdings, money: _money);
    _import = ImportCubit(
      inbox: createImportInbox(extra: _aiApps.inboxPath),
      recognition: _blocs.settings.textRecognition,
      wasImported: _money.wasImported,
      assist: () => _blocs.settings.assist,
      shapes: () => _money.state.settings.messageShapes,
      languages: () => StatementFiles.languagesFor(
          _blocs.settings.state.appLanguage.localeIdentifier ?? WidgetsBinding.instance.platformDispatcher.locale.languageCode),
    );
    _aiApps.onAdded = () => unawaited(_import.checkInbox());
    _blocs.onBookChanged = (key) => key == null ? _money.load() : _money.adoptCloudChanges(key);
    _tapSubscription = notificationTapPayloads.stream.listen(_handleNotificationTap);
    // The money ledger loads after init, once the cloud backend is settled
    // (see AppCubit.init), so a fresh device never seeds over synced data.
    unawaited(_start());
  }

  /// Set when [AppCubit.init] threw, so nothing waits for it for ever.
  bool _initFailed = false;

  /// Start-up. A failure never leaves the app waiting: init's own failure is
  /// logged and stops what waits for it, and a money ledger that cannot be
  /// read is recorded for Settings while the rest carries on.
  Future<void> _start() async {
    try {
      await _blocs.init();
    } catch (error, stack) {
      _initFailed = true;
      debugPrint('Start-up failed: $error\n$stack');
      return;
    }
    try {
      await _money.load();
      // The CloudKit change log sync, if it is on, starts with the book.
      _blocs.cloudLog.bookLoaded();
    } catch (error, stack) {
      debugPrint('Reading the money ledger failed: $error\n$stack');
      await _blocs.sync.noteLoadFailed();
    }
    _aiApps.start();
    // Files shared to Qima while it was closed.
    unawaited(_import.checkInbox());
    await _consumeColdLaunchPayload();
  }

  /// The CloudKit change log sync runs while the app is in the foreground.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_blocs.cloudLog.resumed());
      case AppLifecycleState.paused || AppLifecycleState.hidden || AppLifecycleState.detached:
        _blocs.cloudLog.paused();
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tapSubscription?.cancel();
    unawaited(_blocs.close());
    unawaited(_money.close());
    unawaited(_import.close());
    unawaited(_aiApps.dispose());
    super.dispose();
  }

  Future<void> _consumeColdLaunchPayload() async {
    final payload = await _blocs.alerts.notificationService.consumeLaunchPayload();
    if (payload != null) _handleNotificationTap(payload);
  }

  /// [payload] is either a `WatchCard.id` (a price alert notification, set
  /// in `RefreshPipeline._notify`), [backupReminderNotificationPayload]
  /// (the Phase 6 backup-reminder notification, set in
  /// `BackupReminderNotifier`) or [zakatReminderNotificationPayload] (the
  /// hawl reminder, set in `ZakatReminderNotifier`). Waits for the cubit to
  /// finish initializing (a cold start's tap can arrive before `init()` has
  /// loaded the watchlist) and silently does nothing if a referenced card
  /// was since removed.
  void _handleNotificationTap(String payload) {
    unawaited(() async {
      while (!_blocs.app.state.initialized) {
        if (_initFailed || _blocs.app.isClosed) return;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final navigator = _navigatorKey.currentState;
      if (navigator == null) return;

      if (payload == backupReminderNotificationPayload) {
        navigator.push(MaterialPageRoute(builder: (_) => const BackupScreen()));
        return;
      }
      if (payload == plannedReminderPayload) {
        navigator.push(MaterialPageRoute(builder: (_) => const RecurringScreen()));
        return;
      }
      if (payload == zakatReminderNotificationPayload) {
        navigator.push(MaterialPageRoute(builder: (_) => const ZakatScreen()));
        return;
      }

      WatchCard? card;
      for (final c in _blocs.watchlist.state.cards) {
        if (c.id == payload) {
          card = c;
          break;
        }
      }
      if (card == null) return;
      navigator.push(MaterialPageRoute(builder: (_) => InstrumentDetailScreen(card: card!)));
    }());
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        RepositoryProvider<AiApps>.value(value: _aiApps),
        ..._blocs.providers,
        BlocProvider<MoneyCubit>.value(value: _money),
        BlocProvider<ImportCubit>.value(value: _import),
      ],
      child: BlocBuilder<SettingsCubit, SettingsState>(
        buildWhen: (previous, current) =>
            previous.appLanguage != current.appLanguage || previous.appearance != current.appearance,
        builder: (context, state) {
          return MaterialApp(
            navigatorKey: _navigatorKey,
            onGenerateTitle: (context) => AppLocalizations.of(context)?.appTitle ?? 'Qima',
            debugShowCheckedModeBanner: false,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: state.appLanguage == AppLanguage.system
                ? null
                : Locale(state.appLanguage.localeIdentifier!),
            theme: buildTheme(Brightness.light),
            darkTheme: buildTheme(Brightness.dark),
            themeMode: state.appearance.themeMode,
            // The theme depends on the resolved locale for its font (see
            // `buildTheme`), which is only known here.
            builder: (context, child) {
              final brightness = Theme.of(context).brightness;
              // Screens without an app bar (onboarding, the lock screen)
              // still get status-bar icons that suit the palette.
              final content = AnnotatedRegion<SystemUiOverlayStyle>(
                value: overlayStyleFor(brightness),
                child: Theme(
                  data: buildTheme(brightness, locale: Localizations.localeOf(context)),
                  child: child!,
                ),
              );
              // LockGate sits above the app's screens but below the root
              // ScaffoldMessenger/Navigator that `MaterialApp` itself
              // supplies around `builder`'s output, so in-app snackbars
              // triggered right after unlocking still surface normally.
              // Planned payment reminders follow the plans, in the language
              // the app shows.
              return BlocListener<MoneyCubit, MoneyState>(
                listenWhen: (previous, current) => previous.recurring != current.recurring,
                listener: (context, money) {
                  final l10n = AppLocalizations.of(context);
                  if (l10n == null || !_blocs.app.state.initialized) return;
                  unawaited(PlannedReminders(notifications: _blocs.alerts.notificationService, preferences: _blocs.settings.preferences).sync(money.recurring, l10n));
                },
                child: LockGate(child: content),
              );
            },
            home: const _AppHome(),
          );
        },
      ),
    );
  }
}

/// Decides what the app's first screen is once [AppCubit.init] resolves:
/// setup (shown once, on first launch, before the home shell) when
/// [AppState.shouldShowOnboarding] is true, the home shell otherwise. Stays on a blank loading surface (same
/// as every screen's own `!state.initialized` guard) until init resolves,
/// so this never flashes the shell before deciding.
class _AppHome extends StatelessWidget {
  const _AppHome();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AppCubit, AppState>(
      buildWhen: (previous, current) =>
          previous.initialized != current.initialized || previous.shouldShowOnboarding != current.shouldShowOnboarding,
      builder: (context, state) {
        if (!state.initialized) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (state.shouldShowOnboarding) {
          // Finishing or skipping clears the flag, which brings this
          // builder back round to the home shell.
          return const SetupFlowScreen();
        }
        return const _Home();
      },
    );
  }
}

/// The actual home destination once onboarding is out of the way — watch
/// form factors get their own minimal screen, everything else gets
/// [HomeShell].
class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) {
    return isWatchFormFactor(context) ? const WatchWatchlistScreen() : const HomeShell();
  }
}
