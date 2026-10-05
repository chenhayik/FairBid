/// A pending proposal, on an in-progress job, to change the agreed price
/// (`requestPriceChange` Cloud Function). The counterparty accepts or
/// declines; the proposer may withdraw.
class PriceChangeRequest {
  const PriceChangeRequest({
    required this.by,
    required this.newAmountSen,
    required this.reason,
    this.requestedAt,
  });

  /// `'requestor'` or `'provider'`: who proposed the change.
  final String by;
  final int newAmountSen;
  final String reason;
  final DateTime? requestedAt;

  /// Null when [m] is null or malformed. `requestedAt` must already be a
  /// DateTime (the repository normalises Timestamps).
  static PriceChangeRequest? fromMap(Map<String, dynamic>? m) {
    if (m == null) return null;
    final by = m['by'] as String?;
    final amount = (m['newAmountSen'] as num?)?.toInt();
    if (by == null || amount == null) return null;
    return PriceChangeRequest(
      by: by,
      newAmountSen: amount,
      reason: m['reason'] as String? ?? '',
      requestedAt: m['requestedAt'] as DateTime?,
    );
  }
}
