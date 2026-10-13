import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/requestor_onboarding_data.dart';

/// What:   Requestor onboarding persistence API.
/// Input:  Firestore via FirestoreRequestorOnboardingRepository; a fake in tests.
/// Output: RequestorOnboardingData reads/writes.
abstract interface class RequestorOnboardingRepository {
  Future<RequestorOnboardingData> load(String uid);

  Future<void> save(String uid, RequestorOnboardingData data);

  /// Saves everything, marks onboarding complete, and sets status `pending` only if a document was uploaded.
  Future<void> complete(String uid, RequestorOnboardingData data);
}

/// What:   Firestore-backed [RequestorOnboardingRepository].
/// Input:  Top-level fields on `users/{uid}` plus owner-only `private/verification` and `private/payout`.
/// Output: Batched writes; private fields merged back on load.
class FirestoreRequestorOnboardingRepository
    implements RequestorOnboardingRepository {
  FirestoreRequestorOnboardingRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      _firestore.collection('users').doc(uid);

  /// Owner+admin-only doc with the identity/SSM document URL and SSM number.
  DocumentReference<Map<String, dynamic>> _privateDoc(String uid) =>
      _doc(uid).collection('private').doc('verification');

  /// Owner+admin-only doc with the phone number.
  DocumentReference<Map<String, dynamic>> _payoutDoc(String uid) =>
      _doc(uid).collection('private').doc('payout');

  @override
  Future<RequestorOnboardingData> load(String uid) async {
    final snapshot = await _doc(uid).get();
    final data = RequestorOnboardingData.fromMap(snapshot.data());
    final private = (await _privateDoc(uid).get()).data();
    if (private != null) {
      data
        ..clientDocumentUrl = private['clientDocumentUrl'] as String?
        // Falls back to the legacy public copy.
        ..ssmNumber = private['ssmNumber'] as String? ?? data.ssmNumber
        ..ssmNumberNormalized =
            private['ssmNumberNormalized'] as String? ?? data.ssmNumberNormalized;
    }
    // Falls back to the legacy public phone parsed by fromMap.
    final payout = (await _payoutDoc(uid).get()).data();
    if (payout != null) {
      data.phone = payout['phone'] as String? ?? data.phone;
    }
    return data;
  }

  @override
  Future<void> save(String uid, RequestorOnboardingData data) =>
      _commit(uid, data);

  @override
  Future<void> complete(String uid, RequestorOnboardingData data) =>
      _commit(uid, data, {
        'onboardingComplete': true,
        if (data.clientDocumentUrl != null) 'verificationStatus': 'pending',
        'completedAt': FieldValue.serverTimestamp(),
      });

  /// Writes the profile fields (plus [extra]) and both private docs in one batch.
  /// The phone and SSM number are deleted from the public doc; they live in the private docs.
  Future<void> _commit(
    String uid,
    RequestorOnboardingData data, [
    Map<String, dynamic> extra = const {},
  ]) {
    final batch = _firestore.batch()
      ..set(_doc(uid), {
        ...data.toMap(),
        ...extra,
        'phone': FieldValue.delete(),
        'ssmNumber': FieldValue.delete(),
        'ssmNumberNormalized': FieldValue.delete(),
      }, SetOptions(merge: true))
      ..set(_privateDoc(uid), data.privateMap(), SetOptions(merge: true))
      ..set(_payoutDoc(uid), data.payoutMap(), SetOptions(merge: true));
    return batch.commit();
  }
}
