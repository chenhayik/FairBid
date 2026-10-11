/// What:   Where a provider's withdrawals go.
/// Input:  `users/{uid}/private/payoutMethod` via WalletRepository.watchPayoutMethod().
/// Output: Read-only model; only `savePayoutMethod` writes the doc.
class PayoutMethod {
  const PayoutMethod({
    required this.method,
    required this.masked,
    required this.holderName,
    this.availableAt,
  });

  /// `duitnow` or `bank`.
  final String method;

  /// Safe to show, e.g. "Maybank •••• 1234".
  final String masked;
  final String holderName;

  /// Withdrawals are blocked until this time after a change.
  final DateTime? availableAt;

  bool get isDuitNow => method == 'duitnow';

  bool onHold([DateTime? now]) =>
      availableAt != null && availableAt!.isAfter(now ?? DateTime.now());

  factory PayoutMethod.fromMap(Map<String, dynamic> m) => PayoutMethod(
        method: m['method'] as String? ?? 'bank',
        masked: m['masked'] as String? ?? '',
        holderName: m['holderName'] as String? ?? '',
        availableAt: m['availableAt'] as DateTime?,
      );
}
