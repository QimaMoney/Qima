import 'deterministic_uuid.dart';

/// The id of the cash entry that belonged to the holdings row [transactionId]
/// when a trade was two records: derived from it, so every device links the
/// same pair. Plain Dart, so anything may use it.
String holdingCashId(String transactionId) => deterministicUuid('holding-cash:$transactionId');
