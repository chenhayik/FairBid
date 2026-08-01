import 'package:cloud_firestore/cloud_firestore.dart';

/// Files a "report this user" complaint raised from a public profile.
///
/// Distinct from `ReviewRepository.flagReview`, which reports one *review* on
/// the reviewee's own behalf: this reports a *person*, from a cold profile
/// view, by anyone signed in.
///
/// Reports land in the top-level `reports` collection, readable only by
/// admins (see `firestore.rules`). There is deliberately no client read
/// method: a reporter cannot list or re-read what they filed, which keeps the
/// collection admin-only in practice as well as in the rules.
///
/// NOTE: no admin triage UI reads this collection yet, so a filed report is
/// recorded and auditable but is not yet actioned by anyone. The user-facing
/// copy in `public_profile_screen.dart` is deliberately worded to promise
/// only what actually happens (it was received), never a review timeline.
abstract interface class UserReportRepository {
  /// Files a report against [reportedUid] with the reporter's written
  /// [reason]. Throws on failure so the caller can tell the user it did not
  /// send, rather than silently swallowing it.
  Future<void> reportUser({
    required String reporterId,
    required String reportedUid,
    required String reason,
  });
}

/// Firestore-backed [UserReportRepository]. `status` starts at `'open'` so a
/// future moderation queue can filter on it without a migration.
class FirestoreUserReportRepository implements UserReportRepository {
  FirestoreUserReportRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  @override
  Future<void> reportUser({
    required String reporterId,
    required String reportedUid,
    required String reason,
  }) {
    return _firestore.collection('reports').add({
      'reporterId': reporterId,
      'reportedUid': reportedUid,
      'reason': reason,
      'status': 'open',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
}
