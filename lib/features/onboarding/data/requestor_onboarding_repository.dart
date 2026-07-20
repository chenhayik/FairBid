import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/requestor_onboarding_data.dart';

/// Loads and saves a requestor's onboarding progress.
abstract interface class RequestorOnboardingRepository {
  Future<RequestorOnboardingData> load(String uid);

  Future<void> save(String uid, RequestorOnboardingData data);

  /// Final submission: saves everything, marks onboarding complete, and — only
  /// if a verification document was uploaded — flips `verificationStatus` to
  /// `pending` so it feeds the (future) admin review queue.
  Future<void> complete(String uid, RequestorOnboardingData data);
}

/// Firestore-backed implementation. Requestor fields live at the top level of
/// the `users/{uid}` document (they are general profile data), which the
/// existing security rules already let the owner write.
class FirestoreRequestorOnboardingRepository
    implements RequestorOnboardingRepository {
  FirestoreRequestorOnboardingRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      _firestore.collection('users').doc(uid);

  /// Owner+admin-only doc holding the sensitive identity/SSM document URL.
  DocumentReference<Map<String, dynamic>> _privateDoc(String uid) =>
      _doc(uid).collection('private').doc('verification');

  @override
  Future<RequestorOnboardingData> load(String uid) async {
    final snapshot = await _doc(uid).get();
    final data = RequestorOnboardingData.fromMap(snapshot.data());
    final private = (await _privateDoc(uid).get()).data();
    if (private != null) {
      data.clientDocumentUrl = private['clientDocumentUrl'] as String?;
    }
    return data;
  }

  @override
  Future<void> save(String uid, RequestorOnboardingData data) {
    final batch = _firestore.batch()
      ..set(_doc(uid), data.toMap(), SetOptions(merge: true))
      ..set(_privateDoc(uid), data.privateMap(), SetOptions(merge: true));
    return batch.commit();
  }

  @override
  Future<void> complete(String uid, RequestorOnboardingData data) {
    final batch = _firestore.batch()
      ..set(_doc(uid), {
        ...data.toMap(),
        'onboardingComplete': true,
        if (data.clientDocumentUrl != null) 'verificationStatus': 'pending',
        'completedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true))
      ..set(_privateDoc(uid), data.privateMap(), SetOptions(merge: true));
    return batch.commit();
  }
}
