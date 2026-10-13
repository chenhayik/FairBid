import 'dart:developer' as developer;

/// What:   Diagnostic log for the payment paths (top-up, withdraw), named `fairbid.payment` for filtering.
/// Input:  A [step] name and [data] (sen amounts, bill codes, ids, short statuses); optional error.
/// Output: A developer log line, level 1000 when [error] is set.
/// Notes:  Never put tokens, the toyyibPay secret or full account numbers in [data].
void logPayment(
  String step, {
  Map<String, Object?> data = const {},
  Object? error,
  StackTrace? stackTrace,
}) {
  developer.log(
    data.isEmpty ? step : '$step $data',
    name: 'fairbid.payment',
    error: error,
    stackTrace: stackTrace,
    level: error == null ? 800 : 1000,
  );
}
