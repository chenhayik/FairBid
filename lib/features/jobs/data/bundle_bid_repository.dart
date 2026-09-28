import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/bundle_bid.dart';

/// Thrown by [BundleBidRepository.submit]/[BundleBidRepository.withdraw]
/// when the `submitBundleBid`/`withdrawBundleBid` callable refuses the
/// request. Carries the server's message, written to be shown to the
/// provider as-is - see `createBundle`'s counterpart in
/// `bundle_repository.dart`.
class BundleBidRejectedException implements Exception {
  const BundleBidRejectedException(this.message);
  final String message;
}

/// Reads and writes package bids on a bundle. UI/controllers depend on this
/// interface so tests can use a fake without Firestore.
///
/// Every write goes through a Cloud Function: `firestore.rules` denies all
/// client writes to `bundles/{bundleId}/bundleBids`, because the prices live
/// in a map the rules language cannot walk entry-by-entry. The callables also
/// let the server stamp the provider's name/photo/Trust Score snapshot
/// itself, exactly as `submitBid` does for an ordinary `Bid`.
abstract interface class BundleBidRepository {
  /// Submits (or re-submits, replacing any existing bid) the caller's
  /// package bid on [bundleId] through the `submitBundleBid` callable.
  /// [taskPrices] maps job id to price in sen for each task picked.
  Future<void> submit({
    required String bundleId,
    required Map<String, int> taskPrices,
    int? bundlePriceSen,
    bool allOrNothing = false,
    required String estimatedDuration,
    String message = '',
  });

  /// Withdraws the caller's bid on [bundleId] through the
  /// `withdrawBundleBid` callable.
  Future<void> withdraw(String bundleId);

  /// Streams the signed-in provider's own bid on [bundleId], or null. Rules
  /// only let a provider read their OWN bid, so this is a single-document
  /// read rather than a query - mirrors `BidRepository.watchMyBid`.
  Stream<BundleBid?> watchMyBundleBid(String bundleId, String providerId);

  /// One-shot read of the signed-in provider's own bid on [bundleId], or
  /// null. Used where a live stream's first event isn't safe to trust - e.g.
  /// opening the bid sheet - so the caller gets a single up-to-date snapshot
  /// rather than whatever the local cache serves first.
  Future<BundleBid?> getMyBundleBid(String bundleId, String providerId);

  /// Streams every bid on [bundleId] - the requestor's view of their own
  /// bundle. Mirrors `BidRepository.watchBids`.
  Stream<List<BundleBid>> watchBundleBids(String bundleId);

  /// Streams the provider's own bundle bids across all bundles (newest
  /// first), for the "Pending Bids" list - mirrors
  /// `BidRepository.watchMyBids`.
  Stream<List<BundleBid>> watchMyBundleBids(String providerId);
}

/// Firestore-backed [BundleBidRepository]. Bundle bids live at
/// `bundles/{bundleId}/bundleBids/{uid}` - the provider's uid as the doc id
/// enforces one package bid per provider per bundle.
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
    bool allOrNothing = false,
    required String estimatedDuration,
    String message = '',
  }) async {
    try {
      await _functions.httpsCallable('submitBundleBid').call<void>({
        'bundleId': bundleId,
        'taskPrices': taskPrices,
        'bundlePriceSen': ?bundlePriceSen,
        'allOrNothing': allOrNothing,
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
              // A bundle bid's parent's parent is its bundle document.
              _fromDoc(doc.reference.parent.parent!.id, doc),
          ],
        );
  }

  /// Normalises Firestore Timestamps to DateTime before building the
  /// [BundleBid].
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
