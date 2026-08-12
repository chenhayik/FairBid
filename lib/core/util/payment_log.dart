import 'dart:developer' as developer;

/// Structured diagnostic logging for the payment paths: wallet top-up (both
/// the demo path and the real toyyibPay one), withdraw, and escrow
/// fund/release. A failed payment is the hardest thing to debug from a bug
/// report alone, so every step along these paths logs through here under one
/// consistent `name` so the device log (`flutter logs` / DevTools) can be
/// filtered on it.
///
/// NEVER pass an auth token, the toyyibPay secret key, or a full bank
/// account number in [data] - sen amounts, bill codes, ids and short
/// outcome/status strings only.
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
