import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/public_profile.dart';

/// Read-only access to another user's publicly-safe profile. UI depends on
/// this interface (not `AuthRepository`/`AppUser`) so it can never
/// accidentally read a private field the signed-in user's own profile stream
/// happens to carry - see [PublicProfile] for exactly which fields are
/// excluded and why.
abstract interface class PublicProfileRepository {
  /// Streams [uid]'s public profile, or `null` if the account doesn't exist
  /// (e.g. it was deleted). Never writes.
  Stream<PublicProfile?> watchProfile(String uid);

  /// Current trust scores for [uids], keyed by uid; absent entries mean the
  /// account could not be read.
  ///
  /// Bids carry a `providerTrustScore` copied at bid time, which is fine for
  /// display but wrong to rank on: a provider's score moves after they bid
  /// (a new review, a completed job, a lost dispute), so Best Value would
  /// order today's bids by last week's reputation. Callers resolve the live
  /// score through this before sorting.
  Future<Map<String, ProviderTrust>> fetchTrust(Iterable<String> uids);
}

/// A provider's current, server-computed reputation.
typedef ProviderTrust = ({int trustScore, bool scoreVisible});

/// Firestore-backed [PublicProfileRepository]. Reads only the top-level
/// `users/{uid}` document - the sensitive `private/verification` and
/// `private/payout` subdocuments are never queried here.
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

    // whereIn caps at 30 values per query, so chunk. Bid lists are far
    // smaller than that in practice; the chunking is here so an unusually
    // busy job cannot silently drop the tail of its own bid list.
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
