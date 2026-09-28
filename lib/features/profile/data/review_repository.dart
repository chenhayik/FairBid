import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/review.dart';

/// Thrown by [ReviewRepository.leaveReview] when the reviewer has already
/// reviewed this job (one review per reviewer per job).
class ReviewAlreadyExistsException implements Exception {
  const ReviewAlreadyExistsException();
}

/// Reads and writes reviews left on a user's profile. UI depends on this
/// interface so tests can use a fake without Firestore.
abstract interface class ReviewRepository {
  /// Streams the [limit] newest reviews on [userId]'s profile, newest first,
  /// excluding admin-hidden ones. Capped so a heavily-reviewed profile never
  /// streams its entire subcollection just to show a short preview list. A
  /// single-field `orderBy('createdAt')` inside one subcollection needs no
  /// composite index (hidden is filtered client-side for the same reason).
  Stream<List<Review>> watchReviews(String userId, {int limit = 20});

  /// One page of [userId]'s reviews, newest first, for a paged "See all
  /// reviews" screen. Pass the previous page's last review's `createdAt` as
  /// [startAfter] to fetch the next page; null for the first page. Like
  /// [watchReviews], hidden reviews are filtered out after the query runs, so
  /// a page can come back shorter than [limit] even when more reviews exist.
  Future<List<Review>> fetchReviewPage(
    String userId, {
    int limit = 20,
    DateTime? startAfter,
  });

  /// Records [review] on [revieweeId]'s profile. A Cloud Function recomputes
  /// their Bayesian Trust Score (plan §3.4.3) shortly after. Throws
  /// [ReviewAlreadyExistsException] if the reviewer already reviewed this job
  /// (or, when [bundleId] is given, this bundle - one review per reviewer per
  /// counterparty per bundle).
  Future<void> leaveReview({
    required String revieweeId,
    required Review review,
    String? bundleId,
  });

  /// Whether [reviewerId] already reviewed [revieweeId] for [jobId] (or, when
  /// [bundleId] is given, for that bundle). Lets the UI gate the review
  /// prompt before the reviewer opens the sheet, mirroring the id
  /// [leaveReview] would use.
  Future<bool> hasReviewed({
    required String revieweeId,
    required String jobId,
    required String reviewerId,
    String? bundleId,
  });

  /// Reports a review on [revieweeId]'s profile as unfair/abusive, queueing
  /// it for admin moderation. The review stays visible until an admin rules.
  Future<void> flagReview({
    required String revieweeId,
    required String reviewId,
    required String reason,
    required String flaggedByUid,
  });
}

/// Firestore-backed [ReviewRepository]. Reviews live at
/// `users/{userId}/reviews/{reviewId}`.
class FirebaseReviewRepository implements ReviewRepository {
  FirebaseReviewRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> _reviews(String userId) =>
      _firestore.collection('users').doc(userId).collection('reviews');

  /// One review per reviewer per counterparty per bundle: bundle-keyed when
  /// [bundleId] is given, else keyed by [jobId] as today.
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
                if (_fromDoc(doc) case final review when !review.hidden)
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
        if (_fromDoc(doc) case final review when !review.hidden) review,
    ];
  }

  @override
  Future<void> leaveReview({
    required String revieweeId,
    required Review review,
    String? bundleId,
  }) {
    // Deterministic id → a reviewer can leave at most one review per job (or
    // bundle); the transaction below aborts if it already exists.
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
    // Plain guarded write (see firestore.rules): anyone signed-in may set the
    // flag fields once; hiding/keeping is admin-function-only.
    return _reviews(revieweeId).doc(reviewId).update({
      'flagged': true,
      'flagReason': reason.trim(),
      'flaggedByUid': flaggedByUid,
    });
  }

  /// Normalises Firestore Timestamps to DateTime before building the [Review].
  Review _fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.of(doc.data() ?? {});
    data['createdAt'] = (data['createdAt'] as Timestamp?)?.toDate();
    return Review.fromMap(doc.id, data);
  }
}
