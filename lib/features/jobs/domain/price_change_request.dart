/// What:   A pending proposal to change an in-progress job's agreed price.
/// Input:  Job doc field `priceChangeRequest`, set by the `requestPriceChange` callable.
/// Output: Who proposed ([by]), the new amount and the reason.
class PriceChangeRequest {
  const PriceChangeRequest({
    required this.by,
    required this.newAmountSen,
    required this.reason,
  });

  /// `'requestor'` or `'provider'`.
  final String by;
  final int newAmountSen;
  final String reason;

  /// Null when [m] is null or malformed.
  static PriceChangeRequest? fromMap(Map<String, dynamic>? m) {
    if (m == null) return null;
    final by = m['by'] as String?;
    final amount = (m['newAmountSen'] as num?)?.toInt();
    if (by == null || amount == null) return null;
    return PriceChangeRequest(
      by: by,
      newAmountSen: amount,
      reason: m['reason'] as String? ?? '',
    );
  }
}
