import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/onboarding_data.dart';

/// Loads and saves a provider's onboarding progress.
abstract interface class OnboardingRepository {
  Future<OnboardingData> load(String uid);

  Future<void> save(String uid, OnboardingData data);

  /// Final submission: saves everything and flips the user's
  /// `verificationStatus` to `pending` for admin review.
  Future<void> submitForReview(String uid, OnboardingData data);
}

/// Firestore-backed implementation. Progress lives in an `onboarding` map on
/// the `users/{uid}` document, which the existing security rules already let
/// the owner write.
class FirestoreOnboardingRepository implements OnboardingRepository {
  FirestoreOnboardingRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      _firestore.collection('users').doc(uid);

  /// Owner+admin-only doc holding the sensitive identity photo URLs.
  DocumentReference<Map<String, dynamic>> _privateDoc(String uid) =>
      _doc(uid).collection('private').doc('verification');

  @override
  Future<OnboardingData> load(String uid) async {
    final snapshot = await _doc(uid).get();
    final data = OnboardingData.fromMap(
        snapshot.data()?['onboarding'] as Map<String, dynamic>?);
    // Identity URLs live in the private doc; merge them back for resume.
    final private = (await _privateDoc(uid).get()).data();
    if (private != null) {
      data
        ..idDocumentUrl = private['idDocumentUrl'] as String?
        ..selfieUrl = private['selfieUrl'] as String?;
    }
    return data;
  }

  @override
  Future<void> save(String uid, OnboardingData data) {
    final batch = _firestore.batch()
      ..set(_doc(uid), {'onboarding': data.toMap()}, SetOptions(merge: true))
      ..set(_privateDoc(uid), data.privateMap(), SetOptions(merge: true));
    return batch.commit();
  }

  @override
  Future<void> submitForReview(String uid, OnboardingData data) {
    final batch = _firestore.batch()
      ..set(_doc(uid), {
        'onboarding': data.toMap(),
        'verificationStatus': 'pending',
        // Use the onboarding display name as the public profile name.
        if (data.displayName.isNotEmpty) 'displayName': data.displayName,
        'submittedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true))
      ..set(_privateDoc(uid), data.privateMap(), SetOptions(merge: true));
    return batch.commit();
  }
}
