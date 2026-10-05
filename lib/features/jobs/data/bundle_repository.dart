import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/bundle.dart';
import '../domain/bundle_award.dart';
import '../domain/job.dart';
import 'bid_repository.dart';

/// Thrown by [BundleRepository.create] when `createBundle` refuses the
/// posting. The message comes from the server and can be shown as is.
class BundleRejectedException implements Exception {
  const BundleRejectedException(this.message);
  final String message;
}

/// Reads bundles and creates them through the `createBundle` callable.
/// No update or delete: `firestore.rules` blocks client writes to bundles.
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

  /// Cancels an open bundle (`cancelBundle`) along with its open tasks.
  /// A task in an open bundle can't be cancelled alone (`firestore.rules`).
  Future<void> cancelBundle(String id);

  /// The three award options for [bundleId], priced by `previewBundleAward`.
  /// Empty when no bid covers anything yet.
  Future<List<BundleAwardOption>> previewAward(String bundleId);

  /// Prices the requestor's own picks (task id -> provider id). Returns the
  /// priced pick (key `'manual'`) or the server's problems, never both.
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
      return await _create(
        title: title,
        description: description,
        location: location,
        tasks: tasks,
        photoUrls: photoUrls,
        deadline: deadline,
      );
    } on FirebaseFunctionsException catch (e) {
      throw BundleRejectedException(
        e.message ?? 'Could not post the bundle. Please try again.',
      );
    }
  }

  Future<String> _create({
    required String title,
    required String description,
    required JobLocation location,
    required List<BundleTaskDraft> tasks,
    List<String> photoUrls = const [],
    DateTime? deadline,
  }) async {
    final result = await _functions.httpsCallable('createBundle').call({
      'title': title,
      'description': description,
      'location': location.toMap(),
      'photoUrls': photoUrls,
      if (deadline != null) 'deadlineMillis': deadline.millisecondsSinceEpoch,
      'tasks': [for (final task in tasks) task.toMap()],
    });
    return (result.data as Map)['bundleId'] as String;
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
      // Reports a shortfall like acceptBid, so the same top-up prompt works.
      final details = e.details;
      if (details is Map && details['reason'] == 'insufficient_balance') {
        throw InsufficientBalanceException(
          shortfallSen: (details['shortfallSen'] as num).toInt(),
          availableSen: (details['availableSen'] as num).toInt(),
          requiredSen: (details['requiredSen'] as num).toInt(),
        );
      }
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
