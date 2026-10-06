/// Where a provider's withdrawals go, from `users/{uid}/private/payoutMethod`.
/// Written only by the `savePayoutMethod` function; read-only here.
class PayoutMethod {
  const PayoutMethod({
    required this.method,
    required this.masked,
    required this.holderName,
    this.proxyType,
    this.bankName,
    this.availableAt,
  });

  /// `duitnow` or `bank`.
  final String method;

  /// For DuitNow: `mobile`, `mykad` or `brn`.
  final String? proxyType;
  final String? bankName;

  /// Safe to show, e.g. "Maybank •••• 1234" or "DuitNow 012-•••• 678".
  final String masked;
  final String holderName;

  /// Withdrawals are blocked until this time after a change.
  final DateTime? availableAt;

  bool get isDuitNow => method == 'duitnow';

  bool onHold([DateTime? now]) =>
      availableAt != null && availableAt!.isAfter(now ?? DateTime.now());

  factory PayoutMethod.fromMap(Map<String, dynamic> m) => PayoutMethod(
        method: m['method'] as String? ?? 'bank',
        proxyType: m['proxyType'] as String?,
        bankName: m['bankName'] as String?,
        masked: m['masked'] as String? ?? '',
        holderName: m['holderName'] as String? ?? '',
        availableAt: m['availableAt'] as DateTime?,
      );
}
