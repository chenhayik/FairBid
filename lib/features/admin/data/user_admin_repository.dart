import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/managed_user.dart';

/// What:   Admin user-management API.
/// Input:  Firestore `users` and callables via FirestoreUserAdminRepository; a fake in tests.
/// Output: User stream; suspension and MFA reset go through Cloud Functions (rules deny client writes).
abstract interface class UserAdminRepository {
  /// Every user; the caller orders and filters.
  Stream<List<ManagedUser>> watchUsers();

  /// Suspends or (when [suspended] is false) reinstates [uid], with an optional [reason] shown to them.
  Future<void> setSuspended({
    required String uid,
    required bool suspended,
    String? reason,
  });

  /// Clears every second factor from [uid] (`adminClearMfa`).
  Future<void> clearMfa(String uid);
}

/// What:   Firestore/Functions-backed [UserAdminRepository].
/// Input:  `users` collection, `setUserSuspended`, `adminClearMfa`.
/// Output: ManagedUser stream and action calls.
class FirestoreUserAdminRepository implements UserAdminRepository {
  FirestoreUserAdminRepository(
      {FirebaseFirestore? firestore, FirebaseFunctions? functions})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;

  @override
  Stream<List<ManagedUser>> watchUsers() {
    // No orderBy: it would silently drop legacy docs missing `createdAt`.
    return _firestore.collection('users').snapshots().map((snapshot) => [
          for (final doc in snapshot.docs)
            ManagedUser.fromMap(doc.id, doc.data()),
        ]);
  }

  @override
  Future<void> setSuspended({
    required String uid,
    required bool suspended,
    String? reason,
  }) async {
    await _functions.httpsCallable('setUserSuspended').call<void>({
      'uid': uid,
      'suspended': suspended,
      if (reason != null && reason.isNotEmpty) 'reason': reason,
    });
  }

  @override
  Future<void> clearMfa(String uid) async {
    await _functions.httpsCallable('adminClearMfa').call<void>({'uid': uid});
  }
}
