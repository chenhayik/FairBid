import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/review.dart';

/// What:   Thrown by [ReviewRepository.leaveReview] when the reviewer already reviewed this job or bundle.
/// Input:  Raised inside the leaveReview transaction.
/// Output: The review form shows an "already reviewed" message.
class ReviewAlreadyExistsException implements Exception {
  const ReviewAlreadyExistsException();
}

/// What:   Review API for a user's profile.
/// Input:  Firestore `users/{uid}/reviews` via FirebaseReviewRepository; a fake in tests.
/// Output: Review streams, pages and writes.
abstract interface class ReviewRepository {
  /// The [limit] newest visible reviews on [userId]'s profile; hidden ones are filtered client-side (no composite index).
  Stream<List<Review>> watchReviews(String userId, {int limit = 20});

  /// One page of visible reviews, newest first; pass the last review's `createdAt` as [startAfter].
  /// Hidden ones are filtered after the query, so a page can be shorter than [limit].
  Future<List<Review>> fetchReviewPage(
    String userId, {
    int limit = 20,
    DateTime? startAfter,
  });

  /// Records [review] on [revieweeId]'s profile; a Cloud Function then recomputes their Trust Score.
  /// Throws [ReviewAlreadyExistsException] on a repeat for the job (or [bundleId]).
  Future<void> leaveReview({
    required String revieweeId,
    required Review review,
    String? bundleId,
  });

  /// Whether [reviewerId] already reviewed [revieweeId] for [jobId] (or [bundleId]).
  Future<bool> hasReviewed({
    required String revieweeId,
    required String jobId,
    required String reviewerId,
    String? bundleId,
  });

  /// Reports a review as unfair/abusive for admin moderation; it stays visible until ruled on.
  Future<void> flagReview({
    required String revieweeId,
    required String reviewId,
    required String reason,
    required String flaggedByUid,
  });
}

/// What:   Firestore-backed [ReviewRepository].
/// Input:  `users/{userId}/reviews/{reviewId}`.
/// Output: Reviews as [Review] models.
class FirebaseReviewRepository implements ReviewRepository {
  FirebaseReviewRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> _reviews(String userId) =>
      _firestore.collection('users').doc(userId).collection('reviews');

  /// One review per reviewer per job, or per bundle when [bundleId] is given.
  String _reviewId({
    required String jobId,
    required String reviewerId,
    String? bundleId,
  }) => '${bundleId ?? jobId}_$reviewerId';

  @override
  Stream<List<Review>> watchReviews(String userId, {int limit = 20}) {
    return _reviews(userId)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snapshot) => [
              for (final doc in snapshot.docs)
                if (reviewFromDoc(doc) case final review when !review.hidden)
                  review,
            ]);
  }

  @override
  Future<List<Review>> fetchReviewPage(
    String userId, {
    int limit = 20,
    DateTime? startAfter,
  }) async {
    var query =
        _reviews(userId).orderBy('createdAt', descending: true).limit(limit);
    if (startAfter != null) {
      query = query.startAfter([Timestamp.fromDate(startAfter)]);
    }
    final snapshot = await query.get();
    return [
      for (final doc in snapshot.docs)
        if (reviewFromDoc(doc) case final review when !review.hidden) review,
    ];
  }

  @override
  Future<void> leaveReview({
    required String revieweeId,
    required Review review,
    String? bundleId,
  }) {
    // Deterministic id: the transaction aborts on a repeat review.
    final reviewRef = _reviews(revieweeId).doc(
      _reviewId(
        jobId: review.jobId ?? '',
        reviewerId: review.reviewerId,
        bundleId: bundleId,
      ),
    );
    return _firestore.runTransaction((tx) async {
      final existing = await tx.get(reviewRef);
      if (existing.exists) throw const ReviewAlreadyExistsException();
      tx.set(reviewRef, {
        ...review.toMap(),
        'createdAt': FieldValue.serverTimestamp(),
      });
    });
  }

  @override
  Future<bool> hasReviewed({
    required String revieweeId,
    required String jobId,
    required String reviewerId,
    String? bundleId,
  }) async {
    final id = _reviewId(
      jobId: jobId,
      reviewerId: reviewerId,
      bundleId: bundleId,
    );
    final doc = await _reviews(revieweeId).doc(id).get();
    return doc.exists;
  }

  @override
  Future<void> flagReview({
    required String revieweeId,
    required String reviewId,
    required String reason,
    required String flaggedByUid,
  }) {
    // Rules let any signed-in user set the flag fields once; ruling is admin-function-only.
    return _reviews(revieweeId).doc(reviewId).update({
      'flagged': true,
      'flagReason': reason.trim(),
      'flaggedByUid': flaggedByUid,
    });
  }
}

/// Builds a [Review] from a doc, converting its Timestamp to DateTime.
Review reviewFromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
  final data = Map<String, dynamic>.of(doc.data() ?? {});
  data['createdAt'] = (data['createdAt'] as Timestamp?)?.toDate();
  return Review.fromMap(doc.id, data);
}
