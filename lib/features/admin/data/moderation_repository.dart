import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../../profile/domain/review.dart';
import '../domain/flagged_review.dart';

/// Streams the admin review-moderation queue and records rulings. Ruling goes
/// through the `moderateReview` Cloud Function because hiding a review must
/// also reverse its rating out of the reviewee's protected Trust Score
/// aggregates (which no client may write). UI depends on this interface so
/// tests can use a fake.
abstract interface class ModerationRepository {
  /// Streams every flagged review across all profiles, oldest first.
  Stream<List<FlaggedReview>> watchFlaggedReviews();

  /// Admin ruling: `hide: true` removes the review from public display and
  /// recomputes the reviewee's Trust Score without it; `hide: false` keeps
  /// the review and just clears the flag.
  Future<void> moderateReview({
    required String revieweeId,
    required String reviewId,
    required bool hide,
  });
}

/// Firebase-backed [ModerationRepository].
class FirestoreModerationRepository implements ModerationRepository {
  FirestoreModerationRepository(
      {FirebaseFirestore? firestore, FirebaseFunctions? functions})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;

  @override
  Stream<List<FlaggedReview>> watchFlaggedReviews() {
    return _firestore
        .collectionGroup('reviews')
        .where('flagged', isEqualTo: true)
        .orderBy('createdAt')
        .snapshots()
        .map((snapshot) => [
              for (final doc in snapshot.docs)
                FlaggedReview(
                  // A review's parent's parent is the reviewee's user doc.
                  revieweeId: doc.reference.parent.parent!.id,
                  review: _fromDoc(doc),
                ),
            ]);
  }

  @override
  Future<void> moderateReview({
    required String revieweeId,
    required String reviewId,
    required bool hide,
  }) async {
    await _functions.httpsCallable('moderateReview').call<void>({
      'revieweeId': revieweeId,
      'reviewId': reviewId,
      'hide': hide,
    });
  }

  /// Normalises Firestore Timestamps to DateTime before building the [Review].
  Review _fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.of(doc.data() ?? {});
    data['createdAt'] = (data['createdAt'] as Timestamp?)?.toDate();
    return Review.fromMap(doc.id, data);
  }
}
