/// What:   The kind of money movement a ledger entry records.
/// Input:  The `type` string of the entry via LedgerType.fromStorage().
/// Output: A display [label]; unknown values fall back to top-up.
enum LedgerType {
  fund,
  release,
  topup,
  withdraw,
  disputeRelease,
  disputeRefund,
  refund;

  String get label => switch (this) {
        LedgerType.fund => 'Milestone funded',
        LedgerType.release => 'Payment released',
        LedgerType.topup => 'Top-up',
        LedgerType.withdraw => 'Withdrawal',
        LedgerType.disputeRelease => 'Dispute payout',
        LedgerType.disputeRefund => 'Dispute refund',
        LedgerType.refund => 'Escrow refund',
      };

  static LedgerType fromStorage(String? value) => switch (value) {
        'fund' => LedgerType.fund,
        'release' => LedgerType.release,
        'withdraw' => LedgerType.withdraw,
        'dispute_release' => LedgerType.disputeRelease,
        'dispute_refund' => LedgerType.disputeRefund,
        'refund' => LedgerType.refund,
        _ => LedgerType.topup,
      };
}

/// What:   One entry in the top-level `transactions` ledger.
/// Input:  Doc data via LedgerEntry.fromMap (wallet_repository.dart).
/// Output: Immutable and read-only; only the wallet Cloud Functions append entries.
class LedgerEntry {
  const LedgerEntry({
    required this.id,
    required this.type,
    required this.amountSen,
    this.toUid,
    this.jobTitle,
    this.createdAt,
  });

  final String id;
  final LedgerType type;
  final int amountSen;

  /// Receiving uid; `'escrow'` is the escrow leg, null is the outside world (withdrawal).
  final String? toUid;

  /// The job title at the time, so history rows need no lookup.
  final String? jobTitle;

  final DateTime? createdAt;

  /// Whether this entry moves money *into* [uid]'s wallet.
  bool isCreditFor(String uid) => toUid == uid;

  factory LedgerEntry.fromMap(String id, Map<String, dynamic> m) =>
      LedgerEntry(
        id: id,
        type: LedgerType.fromStorage(m['type'] as String?),
        amountSen: (m['amountSen'] as num?)?.toInt() ?? 0,
        toUid: m['toUid'] as String?,
        jobTitle: m['jobTitle'] as String?,
        createdAt: m['createdAt'] as DateTime?,
      );
}
