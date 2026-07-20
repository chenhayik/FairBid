import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/ledger_entry.dart';

/// Moves money in and out of the simulated wallet and reads the transaction
/// ledger. Both movements call Cloud Functions — Firestore rules reject any
/// client write to `walletBalanceSen` or the `transactions` collection.
/// UI/controllers depend on this interface so tests can use a fake.
abstract interface class WalletRepository {
  /// Demo-only top-up standing in for a payment gateway; credits the caller's
  /// own wallet (the `topUpWallet` Cloud Function).
  Future<void> topUp(int amountSen);

  /// Withdraws from the caller's available balance; the function rejects
  /// overdrafts (the `withdrawFromWallet` Cloud Function).
  Future<void> withdraw(int amountSen);

  /// Streams the user's ledger entries, newest first.
  Stream<List<LedgerEntry>> watchMyTransactions(String uid);
}

/// Firebase-backed [WalletRepository]. Ledger entries live in the top-level
/// `transactions` collection with a `participantIds` array for querying (same
/// shape as `conversations`).
class FirebaseWalletRepository implements WalletRepository {
  FirebaseWalletRepository(
      {FirebaseFirestore? firestore, FirebaseFunctions? functions})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;

  @override
  Future<void> topUp(int amountSen) async {
    await _functions.httpsCallable('topUpWallet').call<void>(
        {'amountSen': amountSen});
  }

  @override
  Future<void> withdraw(int amountSen) async {
    await _functions.httpsCallable('withdrawFromWallet').call<void>(
        {'amountSen': amountSen});
  }

  @override
  Stream<List<LedgerEntry>> watchMyTransactions(String uid) {
    return _firestore
        .collection('transactions')
        .where('participantIds', arrayContains: uid)
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots()
        .map((snapshot) => [
              for (final doc in snapshot.docs) _fromDoc(doc),
            ]);
  }

  /// Normalises Firestore Timestamps to DateTime before building the
  /// [LedgerEntry].
  LedgerEntry _fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.of(doc.data() ?? {});
    data['createdAt'] = (data['createdAt'] as Timestamp?)?.toDate();
    return LedgerEntry.fromMap(doc.id, data);
  }
}
