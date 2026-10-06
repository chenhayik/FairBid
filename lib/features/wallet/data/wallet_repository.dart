import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../../../core/util/payment_log.dart';
import '../domain/ledger_entry.dart';
import '../domain/payout_method.dart';

/// Moves money in and out of the simulated wallet and reads the transaction
/// ledger. Both movements call Cloud Functions - Firestore rules reject any
/// client write to `walletBalanceSen` or the `transactions` collection.
/// UI/controllers depend on this interface so tests can use a fake.
abstract interface class WalletRepository {
  /// Demo-only top-up standing in for a payment gateway; credits the caller's
  /// own wallet (the `topUpWallet` Cloud Function).
  Future<void> topUp(int amountSen);

  /// Withdraws from the caller's available balance; the function rejects
  /// overdrafts (the `withdrawFromWallet` Cloud Function).
  Future<void> withdraw(int amountSen);

  /// Starts a real toyyibPay (sandbox) top-up for [amountSen]: creates a bill
  /// (the `createToyyibpayBill` Cloud Function) and returns its code and
  /// hosted payment page for the caller to open in a WebView. No money moves
  /// yet - that only happens once the bill is confirmed paid server-side.
  Future<({String billCode, String paymentUrl})> createTopUpBill(
      int amountSen);

  /// Asks the server to re-check [billCode] against toyyibPay and credit the
  /// wallet if it hasn't been already (the `reconcileToyyibpayTopup` Cloud
  /// Function) - the safety net for a webhook toyyibPay never delivered.
  /// Returns whether the bill is credited.
  Future<bool> reconcileTopUp(String billCode);

  /// Streams the user's ledger entries, newest first.
  Stream<List<LedgerEntry>> watchMyTransactions(String uid);

  /// Streams where [uid]'s withdrawals go; null until one is set up.
  Stream<PayoutMethod?> watchPayoutMethod(String uid);

  /// Saves a payout method (the `savePayoutMethod` function). DuitNow IDs
  /// come from the verified profile, so only [proxyType] is sent for them.
  Future<void> savePayoutMethod({
    required String method,
    String? proxyType,
    String? bankSwift,
    String? accountNumber,
  });
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
    logPayment('topup.demo.requested', data: {'amountSen': amountSen});
    try {
      await _functions.httpsCallable('topUpWallet').call<void>(
          {'amountSen': amountSen});
      logPayment('topup.demo.result',
          data: {'amountSen': amountSen, 'outcome': 'ok'});
    } on FirebaseFunctionsException catch (e, st) {
      logPayment('topup.demo.error',
          data: {'amountSen': amountSen, 'code': e.code},
          error: e,
          stackTrace: st);
      rethrow;
    }
  }

  @override
  Future<void> withdraw(int amountSen) async {
    logPayment('withdraw.requested', data: {'amountSen': amountSen});
    try {
      await _functions.httpsCallable('withdrawFromWallet').call<void>(
          {'amountSen': amountSen});
      logPayment('withdraw.result',
          data: {'amountSen': amountSen, 'outcome': 'ok'});
    } on FirebaseFunctionsException catch (e, st) {
      logPayment('withdraw.error',
          data: {'amountSen': amountSen, 'code': e.code},
          error: e,
          stackTrace: st);
      rethrow;
    }
  }

  @override
  Future<({String billCode, String paymentUrl})> createTopUpBill(
      int amountSen) async {
    logPayment('topup.bill.requested', data: {'amountSen': amountSen});
    try {
      final result = await _functions
          .httpsCallable('createToyyibpayBill')
          .call<Map<Object?, Object?>>({'amountSen': amountSen});
      final data = result.data;
      final billCode = data['billCode'] as String;
      logPayment('topup.bill.created',
          data: {'amountSen': amountSen, 'billCode': billCode});
      return (billCode: billCode, paymentUrl: data['paymentUrl'] as String);
    } on FirebaseFunctionsException catch (e, st) {
      logPayment('topup.bill.error',
          data: {'amountSen': amountSen, 'code': e.code},
          error: e,
          stackTrace: st);
      rethrow;
    }
  }

  @override
  Future<bool> reconcileTopUp(String billCode) async {
    logPayment('topup.reconcile.requested', data: {'billCode': billCode});
    try {
      final result = await _functions
          .httpsCallable('reconcileToyyibpayTopup')
          .call<Map<Object?, Object?>>({'billCode': billCode});
      final credited = result.data['credited'] as bool? ?? false;
      logPayment('topup.reconcile.result',
          data: {'billCode': billCode, 'credited': credited});
      return credited;
    } on FirebaseFunctionsException catch (e, st) {
      logPayment('topup.reconcile.error',
          data: {'billCode': billCode, 'code': e.code},
          error: e,
          stackTrace: st);
      rethrow;
    }
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

  @override
  Stream<PayoutMethod?> watchPayoutMethod(String uid) {
    return _firestore
        .doc('users/$uid/private/payoutMethod')
        .snapshots()
        .map((snap) {
      final data = snap.data();
      if (data == null) return null;
      final m = Map<String, dynamic>.of(data);
      m['availableAt'] = (m['availableAt'] as Timestamp?)?.toDate();
      return PayoutMethod.fromMap(m);
    });
  }

  @override
  Future<void> savePayoutMethod({
    required String method,
    String? proxyType,
    String? bankSwift,
    String? accountNumber,
  }) async {
    await _functions.httpsCallable('savePayoutMethod').call<void>({
      'method': method,
      'proxyType': ?proxyType,
      'bankSwift': ?bankSwift,
      'accountNumber': ?accountNumber,
    });
  }
}
