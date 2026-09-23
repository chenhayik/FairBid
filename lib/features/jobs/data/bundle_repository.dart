import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/bundle.dart';
import '../domain/job.dart';

/// Thrown by [BundleRepository.create] when the `createBundle` callable
/// refuses the posting - a task without a category, a deadline in the
/// past, more tasks than [PlatformConfig.maxBundleTasks]. Carries the
/// server's message, which is written to be shown to the requestor
/// as-is. Mirrors `BundleBidRejectedException` on the bidding side.
class BundleRejectedException implements Exception {
  const BundleRejectedException(this.message);
  final String message;
}

/// Reads bundled postings and creates them through the `createBundle`
/// callable.
///
/// Deliberately has no update or delete: `bundles/{id}` is server-owned and
/// `firestore.rules` denies every client write to it, exactly like
/// `transactions` and `disputes`. A bundle's tasks are ordinary jobs, so they
/// keep using [JobRepository] - including `watchBundleTasks`, which lives
/// there because it returns [Job]s.
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

  /// Cancels an open bundle through the `cancelBundle` callable, which
  /// cancels its still-open tasks along with it, server-side, in one batch.
  /// A task belonging to an open bundle cannot be cancelled on its own -
  /// `firestore.rules` freezes a task's `status` while its bundle is open,
  /// since the task may be part of an all-or-nothing bid or a lot - so
  /// cancelling the bundle is the only way to call the whole posting off
  /// before it's awarded.
  Future<void> cancelBundle(String id);
}


class FirestoreBundleRepository implements BundleRepository {
  FirestoreBundleRepository({
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
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
    await _functions.httpsCallable('cancelBundle').call<void>({
      'bundleId': id,
    });
  }

  Bundle _fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.of(doc.data() ?? {});
    data['createdAt'] = (data['createdAt'] as Timestamp?)?.toDate();
    data['deadline'] = (data['deadline'] as Timestamp?)?.toDate();
    return Bundle.fromMap(doc.id, data);
  }
}