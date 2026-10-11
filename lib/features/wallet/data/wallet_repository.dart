import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../../../core/util/payment_log.dart';
import '../domain/ledger_entry.dart';
import '../domain/payout_method.dart';

/// What:   Wallet API: top-up, withdraw, payout method and the transaction ledger.
/// Input:  Cloud Functions and Firestore via FirebaseWalletRepository; a fake in tests.
/// Output: Money moves only through functions (rules reject client writes to the balance and `transactions`).
abstract interface class WalletRepository {
  /// Demo top-up crediting the caller's wallet (`topUpWallet`).
  Future<void> topUp(int amountSen);

  /// Withdraws from the available balance; overdrafts are rejected (`withdrawFromWallet`).
  Future<void> withdraw(int amountSen);

  /// Creates a toyyibPay bill (`createToyyibpayBill`) and returns its code and payment page URL.
  /// No money moves until the server confirms payment.
  Future<({String billCode, String paymentUrl})> createTopUpBill(
      int amountSen);

  /// Re-checks [billCode] with toyyibPay and credits the wallet if needed (`reconcileToyyibpayTopup`);
  /// the safety net for a missed webhook. Returns whether it is credited.
  Future<bool> reconcileTopUp(String billCode);

  /// The user's latest ledger entries, newest first.
  Stream<List<LedgerEntry>> watchMyTransactions(String uid);

  /// Where [uid]'s withdrawals go; null until set up.
  Stream<PayoutMethod?> watchPayoutMethod(String uid);

  /// Saves a payout method (`savePayoutMethod`); DuitNow IDs come from the profile, so only [proxyType] is sent.
  Future<void> savePayoutMethod({
    required String method,
    String? proxyType,
    String? bankSwift,
    String? accountNumber,
  });
}

/// What:   Firebase-backed [WalletRepository].
/// Input:  Top-level `transactions` (queried by `participantIds`), `private/payoutMethod` and the wallet callables.
/// Output: Ledger and payout-method streams; payment steps are logged via logPayment.
class FirebaseWalletRepository implements WalletRepository {
  FirebaseWalletRepository(
      {FirebaseFirestore? firestore, FirebaseFunctions? functions})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;

  /// Calls the `name` function with [args], logging `<step>.requested`, then
  /// `<step>.<resultStep>` (with [log]'s extras) or `<step>.error`.
  Future<Object?> _call(
    String name,
    Map<String, Object?> args, {
    required String step,
    String resultStep = 'result',
    Map<String, Object?> Function(Object? data)? log,
  }) async {
    logPayment('$step.requested', data: args);
    try {
      final data =
          (await _functions.httpsCallable(name).call<Object?>(args)).data;
      logPayment('$step.$resultStep', data: {...args, ...?log?.call(data)});
      return data;
    } on FirebaseFunctionsException catch (e, st) {
      logPayment('$step.error',
          data: {...args, 'code': e.code}, error: e, stackTrace: st);
      rethrow;
    }
  }

  @override
  Future<void> topUp(int amountSen) => _call(
        'topUpWallet',
        {'amountSen': amountSen},
        step: 'topup.demo',
        log: (_) => {'outcome': 'ok'},
      );

  @override
  Future<void> withdraw(int amountSen) => _call(
        'withdrawFromWallet',
        {'amountSen': amountSen},
        step: 'withdraw',
        log: (_) => {'outcome': 'ok'},
      );

  @override
  Future<({String billCode, String paymentUrl})> createTopUpBill(
      int amountSen) async {
    final data = await _call(
      'createToyyibpayBill',
      {'amountSen': amountSen},
      step: 'topup.bill',
      resultStep: 'created',
      log: (d) => {'billCode': (d as Map)['billCode']},
    ) as Map<Object?, Object?>;
    return (
      billCode: data['billCode'] as String,
      paymentUrl: data['paymentUrl'] as String,
    );
  }

  @override
  Future<bool> reconcileTopUp(String billCode) async {
    final data = await _call(
      'reconcileToyyibpayTopup',
      {'billCode': billCode},
      step: 'topup.reconcile',
      log: (d) => {'credited': (d as Map)['credited'] as bool? ?? false},
    ) as Map<Object?, Object?>;
    return data['credited'] as bool? ?? false;
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
