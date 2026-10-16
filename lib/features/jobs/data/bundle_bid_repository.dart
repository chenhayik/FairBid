import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/bundle_bid.dart';

/// What:   Thrown when a bundle-bid callable refuses.
/// Input:  [message], server-written.
/// Output: Exception shown as-is.
class BundleBidRejectedException implements Exception {
  const BundleBidRejectedException(this.message);
  final String message;
}

/// What:   Package-bid reads and writes, behind an interface so tests can fake it.
/// Input:  Firestore `bundles/{bundleId}/bundleBids/{uid}`; writes go through callables.
/// Output: BundleBid streams and writes; failures as [BundleBidRejectedException].
/// Notes:  firestore.rules denies client writes; the server stamps name, photo and Trust Score.
abstract interface class BundleBidRepository {
  /// What:   Submits or replaces the caller's package bid.
  /// Input:  [taskPrices] maps job id to sen; optional [bundlePriceSen] for the whole bundle, [estimatedDuration], [message].
  /// Output: Writes through the server callable.
  Future<void> submit({
    required String bundleId,
    required Map<String, int> taskPrices,
    int? bundlePriceSen,
    required String estimatedDuration,
    String message = '',
  });

  /// What:   Withdraws the caller's bid on [bundleId].
  Future<void> withdraw(String bundleId);

  /// What:   Live view of the provider's own bid.
  /// Output: The bid, or null (rules allow only their own).
  Stream<BundleBid?> watchMyBundleBid(String bundleId, String providerId);

  /// What:   One-shot read of the provider's own bid.
  /// Output: The bid, or null; avoids a stale cache hit.
  Future<BundleBid?> getMyBundleBid(String bundleId, String providerId);

  /// What:   Live list of every bid on [bundleId].
  /// Notes:  Owner only.
  Stream<List<BundleBid>> watchBundleBids(String bundleId);

  /// What:   Live list of the provider's bundle bids across bundles.
  /// Output: Bids, newest first.
  Stream<List<BundleBid>> watchMyBundleBids(String providerId);
}

/// What:   Firestore and Cloud Functions [BundleBidRepository].
/// Input:  Firestore `bundles/{id}/bundleBids/{uid}` (one bid per provider) and callables.
/// Output: BundleBid streams and writes.
class FirestoreBundleBidRepository implements BundleBidRepository {
  FirestoreBundleBidRepository({
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;

  DocumentReference<Map<String, dynamic>> _bundle(String bundleId) =>
      _firestore.collection('bundles').doc(bundleId);

  CollectionReference<Map<String, dynamic>> _bundleBids(String bundleId) =>
      _bundle(bundleId).collection('bundleBids');

  @override
  Future<void> submit({
    required String bundleId,
    required Map<String, int> taskPrices,
    int? bundlePriceSen,
    required String estimatedDuration,
    String message = '',
  }) async {
    try {
      await _functions.httpsCallable('submitBundleBid').call<void>({
        'bundleId': bundleId,
        'taskPrices': taskPrices,
        'bundlePriceSen': ?bundlePriceSen,
        'estimatedDuration': estimatedDuration,
        'message': message,
      });
    } on FirebaseFunctionsException catch (e) {
      throw BundleBidRejectedException(
        e.message ?? 'Could not submit your bid. Please try again.',
      );
    }
  }

  @override
  Future<void> withdraw(String bundleId) async {
    try {
      await _functions.httpsCallable('withdrawBundleBid').call<void>({
        'bundleId': bundleId,
      });
    } on FirebaseFunctionsException catch (e) {
      throw BundleBidRejectedException(
        e.message ?? 'Could not withdraw your bid. Please try again.',
      );
    }
  }

  @override
  Stream<BundleBid?> watchMyBundleBid(String bundleId, String providerId) {
    return _bundleBids(bundleId)
        .doc(providerId)
        .snapshots()
        .map((doc) => doc.exists ? _fromDoc(bundleId, doc) : null);
  }

  @override
  Future<BundleBid?> getMyBundleBid(String bundleId, String providerId) async {
    final doc = await _bundleBids(bundleId).doc(providerId).get();
    return doc.exists ? _fromDoc(bundleId, doc) : null;
  }

  @override
  Stream<List<BundleBid>> watchBundleBids(String bundleId) {
    return _bundleBids(bundleId).snapshots().map(
      (snapshot) => [for (final doc in snapshot.docs) _fromDoc(bundleId, doc)],
    );
  }

  @override
  Stream<List<BundleBid>> watchMyBundleBids(String providerId) {
    return _firestore
        .collectionGroup('bundleBids')
        .where('providerId', isEqualTo: providerId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map(
          (snapshot) => [
            for (final doc in snapshot.docs)
              // parent.parent is the bundle.
              _fromDoc(doc.reference.parent.parent!.id, doc),
          ],
        );
  }

  BundleBid _fromDoc(
    String bundleId,
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = Map<String, dynamic>.of(doc.data() ?? {});
    data['createdAt'] = (data['createdAt'] as Timestamp?)?.toDate();
    data['updatedAt'] = (data['updatedAt'] as Timestamp?)?.toDate();
    return BundleBid.fromMap(bundleId, doc.id, data);
  }
}
