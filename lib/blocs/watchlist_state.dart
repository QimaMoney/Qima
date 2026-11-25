import 'package:equatable/equatable.dart';

import '../models/watch_card.dart';

/// The cards on the watchlist, in the order shown.
class WatchlistState extends Equatable {
  final List<WatchCard> cards;

  const WatchlistState({this.cards = const []});

  WatchlistState copyWith({List<WatchCard>? cards}) => WatchlistState(cards: cards ?? this.cards);

  @override
  List<Object?> get props => [cards];
}
