import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/public_profile.dart';

/// What:   Read-only access to another user's public-safe profile.
/// Input:  Firestore `users/{uid}` via FirebasePublicProfileRepository; a fake in tests.
/// Output: [PublicProfile] (see its doc for the excluded private fields) and live trust scores.
abstract interface class PublicProfileRepository {
  /// [uid]'s public profile; `null` if the account doesn't exist.
  Stream<PublicProfile?> watchProfile(String uid);

  /// Current trust scores for [uids], keyed by uid (unreadable accounts are absent).
  /// Bids carry a stale `providerTrustScore`, so Best Value ranks on these live scores.
  Future<Map<String, ProviderTrust>> fetchTrust(Iterable<String> uids);
}

typedef ProviderTrust = ({int trustScore, bool scoreVisible});

/// What:   Firestore-backed [PublicProfileRepository].
/// Input:  Only the top-level `users/{uid}` doc; the private subdocs are never queried.
/// Output: PublicProfile values and a uid-to-ProviderTrust map.
class FirebasePublicProfileRepository implements PublicProfileRepository {
  FirebasePublicProfileRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  @override
  Stream<PublicProfile?> watchProfile(String uid) {
    return _firestore.collection('users').doc(uid).snapshots().map((
      snapshot,
    ) {
      final data = snapshot.data();
      return data == null ? null : PublicProfile.fromMap(uid, data);
    });
  }

  @override
  Future<Map<String, ProviderTrust>> fetchTrust(Iterable<String> uids) async {
    final ids = uids.toSet().toList();
    if (ids.isEmpty) return const {};

    // whereIn caps at 30 values per query.
    const chunkSize = 30;
    final result = <String, ProviderTrust>{};
    for (var i = 0; i < ids.length; i += chunkSize) {
      final chunk = ids.sublist(
        i,
        i + chunkSize > ids.length ? ids.length : i + chunkSize,
      );
      final snapshot = await _firestore
          .collection('users')
          .where(FieldPath.documentId, whereIn: chunk)
          .get();
      for (final doc in snapshot.docs) {
        final profile = PublicProfile.fromMap(doc.id, doc.data());
        result[doc.id] = (
          trustScore: profile.trustScore,
          scoreVisible: profile.scoreVisible,
        );
      }
    }
    return result;
  }
}
