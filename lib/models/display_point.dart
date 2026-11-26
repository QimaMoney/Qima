import 'package:equatable/equatable.dart';

/// A single (date, value) sample already converted into display
/// currency/unit/karat terms — the output of [PriceConverter.points].
class DisplayPoint extends Equatable {
  /// Device-local, whatever [date] was given in: history bars and stored
  /// quotes come back in UTC, and every axis label, scrub callout and
  /// spoken description formats this field as it is.
  final DateTime date;
  final double value;

  /// The extremes of the span this point stands for, in the same terms as
  /// [value]. Null where only the value is known.
  final double? high;
  final double? low;

  /// The price that span started at, in the same terms as [value]. Null
  /// where the feed didn't say.
  final double? open;

  DisplayPoint({required DateTime date, required this.value, this.high, this.low, this.open}) : date = date.toLocal();

  /// The highest price the point stands for: its own extreme, else its value.
  double get peak => high ?? value;

  /// The lowest price the point stands for: its own extreme, else its value.
  double get trough => low ?? value;

  @override
  List<Object?> get props => [date, value, high, low, open];
}
