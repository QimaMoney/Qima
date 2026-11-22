import 'package:equatable/equatable.dart';

import '../models/setup_answers.dart';

/// What the whole app waits on and decides once: whether start-up has
/// finished, and the first-run state (setup and the guided tour). Everything
/// else lives in the cubit that owns it; see `AppBlocs`.
class AppState extends Equatable {
  /// True once every cubit has loaded; screens show nothing until then.
  final bool initialized;

  /// Whether the first-launch onboarding tour should be presented before
  /// the home shell (spec "Onboarding tour"). Decided once in
  /// [AppCubit.init]: false once `Preferences.onboardingCompleted` is set,
  /// and also false for an existing (pre-onboarding) install that already
  /// has real user data — see [AppCubit.completeOnboarding] and
  /// `AppCubit._hasExistingUserData`. Stays false until [initialized] to
  /// avoid flashing the tour on for a frame before init resolves.
  final bool shouldShowOnboarding;

  /// What the person answered in setup on this device, or null when they
  /// skipped it; see `Preferences.setupAnswers`.
  final SetupAnswers? setup;

  /// The person closed Home's Get started card.
  final bool getStartedDismissed;

  /// The guided tour was asked for and the home shell has not started it
  /// yet. Never stored.
  final bool tourRequested;

  const AppState({
    this.initialized = false,
    this.shouldShowOnboarding = false,
    this.setup,
    this.getStartedDismissed = false,
    this.tourRequested = false,
  });

  AppState copyWith({
    bool? initialized,
    bool? shouldShowOnboarding,
    SetupAnswers? setup,
    bool? getStartedDismissed,
    bool? tourRequested,
  }) {
    return AppState(
      initialized: initialized ?? this.initialized,
      shouldShowOnboarding: shouldShowOnboarding ?? this.shouldShowOnboarding,
      setup: setup ?? this.setup,
      getStartedDismissed: getStartedDismissed ?? this.getStartedDismissed,
      tourRequested: tourRequested ?? this.tourRequested,
    );
  }

  @override
  List<Object?> get props => [initialized, shouldShowOnboarding, setup, getStartedDismissed, tourRequested];
}
