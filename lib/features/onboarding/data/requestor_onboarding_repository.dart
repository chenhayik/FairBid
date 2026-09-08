import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/requestor_onboarding_data.dart';

/// Loads and saves a requestor's onboarding progress.
abstract interface class RequestorOnboardingRepository {
  Future<RequestorOnboardingData> load(String uid);

  Future<void> save(String uid, RequestorOnboardingData data);

  /// Final submission: saves everything, marks onboarding complete, and - only
  /// if a verification document was uploaded - flips `verificationStatus` to
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

  /// Owner+admin-only doc holding the phone number (see
  /// `RequestorOnboardingData.payoutMap`), never on the world-readable
  /// public doc.
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
        // Falls back to whatever fromMap read off the public document, for
        // accounts that have not saved since the SSM-privacy migration below.
        ..ssmNumber = private['ssmNumber'] as String? ?? data.ssmNumber
        ..ssmNumberNormalized =
            private['ssmNumberNormalized'] as String? ?? data.ssmNumberNormalized;
    }
    // Phone lives in its own private doc too; merge it back for resume,
    // falling back to the legacy public field (still parsed by
    // RequestorOnboardingData.fromMap above) for accounts that haven't saved
    // since the migration.
    final payout = (await _payoutDoc(uid).get()).data();
    if (payout != null) {
      data.phone = payout['phone'] as String? ?? data.phone;
    }
    return data;
  }

  @override
  Future<void> save(String uid, RequestorOnboardingData data) {
    final batch = _firestore.batch()
      ..set(_doc(uid), {
        ...data.toMap(),
        // MIGRATION: phone used to live at the top level; strip it from the
        // public doc as each user saves so legacy data migrates organically.
        // A one-off backfill Cloud Function is still needed for users who
        // never save again - deliberately out of scope here.
        'phone': FieldValue.delete(),
        // MIGRATION: so did the SSM number, which is personal data for a sole
        // proprietorship. It now lives in `private/verification`.
        'ssmNumber': FieldValue.delete(),
        'ssmNumberNormalized': FieldValue.delete(),
      }, SetOptions(merge: true))
      ..set(_privateDoc(uid), data.privateMap(), SetOptions(merge: true))
      ..set(_payoutDoc(uid), data.payoutMap(), SetOptions(merge: true));
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
        'phone': FieldValue.delete(),
        'ssmNumber': FieldValue.delete(),
        'ssmNumberNormalized': FieldValue.delete(),
      }, SetOptions(merge: true))
      ..set(_privateDoc(uid), data.privateMap(), SetOptions(merge: true))
      ..set(_payoutDoc(uid), data.payoutMap(), SetOptions(merge: true));
    return batch.commit();
  }
}
