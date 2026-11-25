import 'package:equatable/equatable.dart';

import '../models/zakat.dart';

/// Zakat choices (v3) — synced like the base currency, see
/// `Preferences.zakatSettings`.
class ZakatState extends Equatable {
  final ZakatSettings settings;

  const ZakatState({this.settings = const ZakatSettings()});

  @override
  List<Object?> get props => [settings];
}
