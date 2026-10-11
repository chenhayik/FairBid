import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/bundle.dart';
import '../domain/bundle_award.dart';
import '../domain/job.dart';
import 'bid_repository.dart';

/// What:   Thrown when a bundle callable refuses the request.
/// Input:  [message], server-written.
/// Output: Exception shown as-is.
class BundleRejectedException implements Exception {
  const BundleRejectedException(this.message);
  final String message;
}

/// What:   Bundle reads plus the create, cancel and award callables.
/// Input:  Firestore `bundles` and Cloud Functions, via FirestoreBundleRepository.
/// Output: Bundles and priced award options; failures as [BundleRejectedException].
/// Notes:  firestore.rules blocks client writes to bundles.
abstract interface class BundleRepository {
  Future<String> create({
    required String title,
    required String description,
    required JobLocation location,
    required List<BundleTaskDraft> tasks,
    List<String> photoUrls,
    DateTime? deadline,
  });

  Stream<Bundle?> watchBundle(String id);

  Stream<List<Bundle>> watchMyBundles(String requestorId);

  Future<Bundle?> getById(String id);

  /// Cancels an open bundle and its open tasks (a task can't be cancelled alone).
  Future<void> cancelBundle(String id);

  /// The award options for [bundleId]; empty when no bid covers anything yet.
  Future<List<BundleAwardOption>> previewAward(String bundleId);

  /// Prices the requestor's own picks (task id -> provider id): the priced option or the problems, never both.
  Future<({BundleAwardOption? option, List<String> problems})> priceManualAward(
    String bundleId,
    Map<String, String> providerByTaskId,
  );

  /// Awards the tasks in [providerByTaskId]; the rest go back to bidding.
  /// Refused if the total differs from [expectedTotalSen] or balance is short.
  Future<void> award({
    required String bundleId,
    required Map<String, String> providerByTaskId,
    int? expectedTotalSen,
    DateTime? releasedDeadline,
    bool dropUnawarded = false,
  });
}

/// What:   Firestore and Cloud Functions [BundleRepository].
/// Input:  Firestore `bundles` and callables.
/// Output: Bundles and award options.
class FirestoreBundleRepository implements BundleRepository {
  FirestoreBundleRepository({
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;

  CollectionReference<Map<String, dynamic>> get _bundles =>
      _firestore.collection('bundles');

  @override
  Future<String> create({
    required String title,
    required String description,
    required JobLocation location,
    required List<BundleTaskDraft> tasks,
    List<String> photoUrls = const [],
    DateTime? deadline,
  }) async {
    try {
      final result = await _functions.httpsCallable('createBundle').call({
        'title': title,
        'description': description,
        'location': location.toMap(),
        'photoUrls': photoUrls,
        if (deadline != null) 'deadlineMillis': deadline.millisecondsSinceEpoch,
        'tasks': [for (final task in tasks) task.toMap()],
      });
      return (result.data as Map)['bundleId'] as String;
    } on FirebaseFunctionsException catch (e) {
      throw BundleRejectedException(
        e.message ?? 'Could not post the bundle. Please try again.',
      );
    }
  }

  @override
  Stream<Bundle?> watchBundle(String id) => _bundles
      .doc(id)
      .snapshots()
      .map((doc) => doc.exists ? _fromDoc(doc) : null);

  @override
  Stream<List<Bundle>> watchMyBundles(String requestorId) => _bundles
      .where('requestorId', isEqualTo: requestorId)
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((snapshot) => snapshot.docs.map(_fromDoc).toList());

  @override
  Future<Bundle?> getById(String id) async {
    final doc = await _bundles.doc(id).get();
    return doc.exists ? _fromDoc(doc) : null;
  }

  @override
  Future<void> cancelBundle(String id) async {
    try {
      await _functions.httpsCallable('cancelBundle').call<void>({
        'bundleId': id,
      });
    } on FirebaseFunctionsException catch (e) {
      throw BundleRejectedException(
        e.message ?? 'Could not cancel the bundle. Please try again.',
      );
    }
  }

  @override
  Future<List<BundleAwardOption>> previewAward(String bundleId) async {
    try {
      final result = await _functions.httpsCallable('previewBundleAward').call({
        'bundleId': bundleId,
      });
      final options = (result.data as Map)['options'] as List? ?? const [];
      return [
        for (final option in options.whereType<Map>())
          BundleAwardOption.fromMap(Map<String, dynamic>.from(option)),
      ];
    } on FirebaseFunctionsException catch (e) {
      throw BundleRejectedException(
        e.message ?? 'Could not work out the award options.',
      );
    }
  }

  @override
  Future<({BundleAwardOption? option, List<String> problems})> priceManualAward(
    String bundleId,
    Map<String, String> providerByTaskId,
  ) async {
    try {
      final result = await _functions.httpsCallable('previewBundleAward').call({
        'bundleId': bundleId,
        'providerByTaskId': providerByTaskId,
      });
      final data = Map<String, dynamic>.from(result.data as Map);
      final manual = data['manual'];
      final problems =
          (data['problems'] as List?)?.whereType<String>().toList() ?? const [];
      return (
        option: manual is Map
            ? BundleAwardOption.fromMap(Map<String, dynamic>.from(manual))
            : null,
        problems: problems,
      );
    } on FirebaseFunctionsException catch (e) {
      throw BundleRejectedException(e.message ?? 'Could not price your pick.');
    }
  }

  @override
  Future<void> award({
    required String bundleId,
    required Map<String, String> providerByTaskId,
    int? expectedTotalSen,
    DateTime? releasedDeadline,
    bool dropUnawarded = false,
  }) async {
    try {
      await _functions.httpsCallable('awardBundle').call<void>({
        'bundleId': bundleId,
        'providerByTaskId': providerByTaskId,
        'expectedTotalSen': ?expectedTotalSen,
        if (dropUnawarded) 'dropUnawarded': true,
        if (releasedDeadline != null)
          'releasedDeadlineMillis': releasedDeadline.millisecondsSinceEpoch,
      });
    } on FirebaseFunctionsException catch (e) {
      // A shortfall is reported like acceptBid, so the same top-up prompt works.
      final shortfall = InsufficientBalanceException.from(e);
      if (shortfall != null) throw shortfall;
      throw BundleRejectedException(
        e.message ?? 'Could not award this bundle. Please try again.',
      );
    }
  }

  Bundle _fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.of(doc.data() ?? {});
    data['createdAt'] = (data['createdAt'] as Timestamp?)?.toDate();
    data['deadline'] = (data['deadline'] as Timestamp?)?.toDate();
    return Bundle.fromMap(doc.id, data);
  }
}
