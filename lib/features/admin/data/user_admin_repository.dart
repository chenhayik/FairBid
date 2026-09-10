import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/managed_user.dart';

/// Admin-only: lists users and suspends/reinstates them. Suspension flips a
/// server-owned flag via the `setUserSuspended` Cloud Function - Firestore
/// rules deny any client write to it - so this never touches the flag
/// directly. UI depends on this interface so tests can use a fake.
abstract interface class UserAdminRepository {
  /// Streams every user for the admin "Users" list. Ordering and filtering
  /// (search, hide admins) are applied client-side by the caller.
  Stream<List<ManagedUser>> watchUsers();

  /// Suspends (or, when [suspended] is false, reinstates) [uid], with an
  /// optional [reason] shown to the user (`setUserSuspended`).
  Future<void> setSuspended({
    required String uid,
    required bool suspended,
    String? reason,
  });

  /// Clears every second factor from [uid] - the recovery path for a user who
  /// lost their authenticator app (`adminClearMfa`).
  Future<void> clearMfa(String uid);
}

/// Firestore/Functions-backed [UserAdminRepository].
class FirestoreUserAdminRepository implements UserAdminRepository {
  FirestoreUserAdminRepository(
      {FirebaseFirestore? firestore, FirebaseFunctions? functions})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;

  @override
  Stream<List<ManagedUser>> watchUsers() {
    // No orderBy: a `createdAt` order would silently drop any legacy user doc
    // missing the field. The list is small (admin-only) and the caller sorts.
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
