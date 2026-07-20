/// The kind of money movement a ledger entry records.
enum LedgerType {
  fund,
  release,
  topup,
  withdraw,
  disputeRelease,
  disputeRefund;

  String get label => switch (this) {
        LedgerType.fund => 'Milestone funded',
        LedgerType.release => 'Payment released',
        LedgerType.topup => 'Top-up',
        LedgerType.withdraw => 'Withdrawal',
        LedgerType.disputeRelease => 'Dispute payout',
        LedgerType.disputeRefund => 'Dispute refund',
      };

  static LedgerType fromStorage(String? value) => switch (value) {
        'fund' => LedgerType.fund,
        'release' => LedgerType.release,
        'withdraw' => LedgerType.withdraw,
        'dispute_release' => LedgerType.disputeRelease,
        'dispute_refund' => LedgerType.disputeRefund,
        _ => LedgerType.topup,
      };
}

/// One immutable entry in the top-level `transactions` ledger. Read-only on
/// the client — only the wallet Cloud Functions (admin SDK) append entries,
/// so there is no `toMap()`.
class LedgerEntry {
  const LedgerEntry({
    required this.id,
    required this.type,
    required this.amountSen,
    this.fromUid,
    this.toUid,
    this.jobId,
    this.jobTitle,
    this.milestoneId,
    this.createdAt,
  });

  final String id;
  final LedgerType type;
  final int amountSen;

  /// Sending/receiving uid. `'escrow'` marks the escrow leg of a fund/release;
  /// null marks the outside world (top-up source, withdrawal destination).
  final String? fromUid;
  final String? toUid;

  final String? jobId;

  /// The job's title at fund/release time, so history rows are tellable
  /// apart without a lookup.
  final String? jobTitle;

  final String? milestoneId;
  final DateTime? createdAt;

  /// Whether this entry moves money *into* [uid]'s wallet.
  bool isCreditFor(String uid) => toUid == uid;

  /// Builds a [LedgerEntry] from its doc id and (already
  /// Timestamp-normalised) data map.
  factory LedgerEntry.fromMap(String id, Map<String, dynamic> m) =>
      LedgerEntry(
        id: id,
        type: LedgerType.fromStorage(m['type'] as String?),
        amountSen: (m['amountSen'] as num?)?.toInt() ?? 0,
        fromUid: m['fromUid'] as String?,
        toUid: m['toUid'] as String?,
        jobId: m['jobId'] as String?,
        jobTitle: m['jobTitle'] as String?,
        milestoneId: m['milestoneId'] as String?,
        createdAt: m['createdAt'] as DateTime?,
      );
}
