import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/face_box.dart';
import '../domain/id_extract.dart';
import '../domain/onboarding_data.dart';
import '../domain/ssm_extract.dart';

/// What:   Provider onboarding persistence API.
/// Input:  Firestore via FirestoreOnboardingRepository; a fake in tests.
/// Output: OnboardingData reads/writes and the SSM/ID extract streams.
abstract interface class OnboardingRepository {
  Future<OnboardingData> load(String uid);

  Future<void> save(String uid, OnboardingData data);

  /// Saves everything and sets `verificationStatus` to `pending`.
  Future<void> submitForReview(String uid, OnboardingData data);

  /// The server's SSM reading, null while none exists (`extractSsmDocument` writes it).
  Stream<SsmExtract?> watchSsmExtract(String uid);

  /// The server's ID photo reading, null while none exists (`extractIdDocument` writes it).
  Stream<IdExtract?> watchIdExtract(String uid);
}

/// What:   Firestore-backed [OnboardingRepository].
/// Input:  `onboarding` map on `users/{uid}` plus owner-only `private/verification`.
/// Output: Batched writes; identity URLs merged back on load.
class FirestoreOnboardingRepository implements OnboardingRepository {
  FirestoreOnboardingRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      _firestore.collection('users').doc(uid);

  /// Owner+admin-only doc with the identity photo URLs.
  DocumentReference<Map<String, dynamic>> _privateDoc(String uid) =>
      _doc(uid).collection('private').doc('verification');

  /// Legacy public bank fields, removed on every save (now in `private/payoutMethod`).
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
  Future<void> save(String uid, OnboardingData data) => _commit(uid, data);

  @override
  Future<void> submitForReview(String uid, OnboardingData data) =>
      _commit(uid, data, {
        'verificationStatus': 'pending',
        if (data.displayName.isNotEmpty) 'displayName': data.displayName,
        'submittedAt': FieldValue.serverTimestamp(),
      });

  /// What:   Writes the provider's onboarding data.
  /// Input:  [uid]; [data] (public map and private map); optional [extra] top-level fields.
  /// Output: One batch: the `onboarding` map, removal of legacy public bank fields, and the private verification doc.
  Future<void> _commit(
    String uid,
    OnboardingData data, [
    Map<String, dynamic> extra = const {},
  ]) {
    final batch = _firestore.batch()
      ..set(_doc(uid), {'onboarding': data.toMap(), ...extra},
          SetOptions(merge: true))
      ..update(_doc(uid), _legacyPayoutDeletes)
      ..set(_privateDoc(uid), data.privateMap(), SetOptions(merge: true));
    return batch.commit();
  }
}
