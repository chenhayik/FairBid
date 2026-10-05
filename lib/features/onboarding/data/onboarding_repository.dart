import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/face_box.dart';
import '../domain/id_extract.dart';
import '../domain/onboarding_data.dart';
import '../domain/ssm_extract.dart';

/// Loads and saves a provider's onboarding progress.
abstract interface class OnboardingRepository {
  Future<OnboardingData> load(String uid);

  Future<void> save(String uid, OnboardingData data);

  /// Final submission: saves everything and flips the user's
  /// `verificationStatus` to `pending` for admin review.
  Future<void> submitForReview(String uid, OnboardingData data);

  /// Streams the server's reading of the uploaded SSM document, or null while
  /// none exists. Written only by the `extractSsmDocument` Cloud Function.
  Stream<SsmExtract?> watchSsmExtract(String uid);

  /// Streams the server's reading of the uploaded ID photo, or null while none
  /// exists. Written only by the `extractIdDocument` Cloud Function.
  Stream<IdExtract?> watchIdExtract(String uid);
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

  /// Owner+admin-only doc holding the payout bank details (see
  /// `OnboardingData.payoutMap`), never on the world-readable public doc.
  DocumentReference<Map<String, dynamic>> _payoutDoc(String uid) =>
      _doc(uid).collection('private').doc('payout');

  /// Fields whose public home moved to [_payoutDoc]; explicitly deleted from
  /// the public `onboarding` map on every subsequent save so legacy accounts
  /// migrate organically. A one-off backfill Cloud Function is still needed
  /// for providers who never save again - deliberately out of scope here.
  static final _legacyPayoutDeletes = {
    'onboarding.bankName': FieldValue.delete(),
    'onboarding.accountHolder': FieldValue.delete(),
    'onboarding.accountLast4': FieldValue.delete(),
    'onboarding.branchCode': FieldValue.delete(),
  };

  static Map<String, dynamic>? _map(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : null;

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
        ..selfieUrl = private['selfieUrl'] as String?
        ..ssmDocumentUrl = private['ssmDocumentUrl'] as String?
        ..icNumber = private['icNumber'] as String? ?? ''
        ..idFaceBox = FaceBox.fromMap(_map(private['idFaceBox']))
        ..selfieFaceBox = FaceBox.fromMap(_map(private['selfieFaceBox']))
        ..idConsentAt = (private['idConsentAt'] as Timestamp?)?.toDate()
        ..ssmNumber = private['ssmNumber'] as String? ?? ''
        ..ssmNumberNormalized =
            private['ssmNumberNormalized'] as String? ?? '';
    }
    // Payout bank details live in their own private doc too; merge them back
    // for resume, falling back to the legacy public onboarding fields (still
    // parsed by OnboardingData.fromMap above) for accounts that haven't saved
    // since the migration.
    final payout = (await _payoutDoc(uid).get()).data();
    if (payout != null) {
      data
        ..bankName = payout['bankName'] as String? ?? data.bankName
        ..accountHolder =
            payout['accountHolder'] as String? ?? data.accountHolder
        ..branchCode = payout['branchCode'] as String? ?? data.branchCode;
    }
    return data;
  }

  @override
  Stream<SsmExtract?> watchSsmExtract(String uid) => _doc(uid)
      .collection('private')
      .doc('ssmExtract')
      .snapshots()
      .map((snapshot) => SsmExtract.fromMap(snapshot.data()));

  @override
  Stream<IdExtract?> watchIdExtract(String uid) => _doc(uid)
      .collection('private')
      .doc('idExtract')
      .snapshots()
      .map((snapshot) => IdExtract.fromMap(snapshot.data()));

  @override
  Future<void> save(String uid, OnboardingData data) {
    final batch = _firestore.batch()
      ..set(_doc(uid), {'onboarding': data.toMap()}, SetOptions(merge: true))
      ..update(_doc(uid), _legacyPayoutDeletes)
      ..set(_privateDoc(uid), data.privateMap(), SetOptions(merge: true))
      ..set(_payoutDoc(uid), data.payoutMap(), SetOptions(merge: true));
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
      ..update(_doc(uid), _legacyPayoutDeletes)
      ..set(_privateDoc(uid), data.privateMap(), SetOptions(merge: true))
      ..set(_payoutDoc(uid), data.payoutMap(), SetOptions(merge: true));
    return batch.commit();
  }
}
