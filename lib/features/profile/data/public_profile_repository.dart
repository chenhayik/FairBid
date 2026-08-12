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
}

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
}
