import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../../profile/data/review_repository.dart';
import '../domain/flagged_review.dart';

/// What:   Admin review-moderation API.
/// Input:  Firestore collection group `reviews` via FirestoreModerationRepository; a fake in tests.
/// Output: Flagged-review stream; rulings go through `moderateReview` because hiding must reverse the protected Trust Score aggregates.
abstract interface class ModerationRepository {
  /// Every flagged review across all profiles, oldest first.
  Stream<List<FlaggedReview>> watchFlaggedReviews();

  /// Admin ruling: [hide] removes the review and recomputes the Trust Score; otherwise it clears the flag.
  Future<void> moderateReview({
    required String revieweeId,
    required String reviewId,
    required bool hide,
  });
}

/// What:   Firebase-backed [ModerationRepository].
/// Input:  Firestore and the `moderateReview` callable.
/// Output: FlaggedReview stream and ruling calls.
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
                  review: reviewFromDoc(doc),
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
}
