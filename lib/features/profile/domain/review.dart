/// A review left on a user's profile after a completed job. Stored at
/// `users/{revieweeId}/reviews/{reviewId}`; the reviewee's uid is the path, so
/// it is not a stored field. Framework-agnostic — the repository handles the
/// Firestore ↔ [Review] mapping.
class Review {
  const Review({
    required this.id,
    required this.reviewerId,
    required this.reviewerName,
    this.reviewerPhotoUrl,
    required this.rating,
    this.comment = '',
    this.jobId,
    this.jobTitle,
    this.createdAt,
    this.flagged = false,
    this.flagReason,
    this.flaggedByUid,
    this.hidden = false,
  });

  /// The review document's id (its path, not a stored field).
  final String id;
  final String reviewerId;
  final String reviewerName;

  /// Snapshot of the reviewer's `profilePhotoUrl` at review time, denormalised
  /// so the review list shows a face without loading the reviewer's profile —
  /// mirrors how [reviewerName] is already denormalised. Null if the reviewer
  /// had no photo when they reviewed. A future Cloud Function could refresh
  /// this snapshot if the reviewer later changes their photo.
  final String? reviewerPhotoUrl;

  /// Star rating, 1–5.
  final int rating;
  final String comment;
  final String? jobId;
  final String? jobTitle;
  final DateTime? createdAt;

  /// Moderation state. A reviewee reports an unfair review (`flagged` + the
  /// reason), and an admin either hides it (`hidden`, which also reverses its
  /// effect on the Trust Score, server-side) or keeps it (flag cleared).
  final bool flagged;
  final String? flagReason;
  final String? flaggedByUid;
  final bool hidden;

  /// Fields written to Firestore. `createdAt` for a new review is set by the
  /// repository (server timestamp); the moderation fields are never part of a
  /// new review (flagging/hiding write them later), so both are omitted here.
  Map<String, dynamic> toMap() => {
        'reviewerId': reviewerId,
        'reviewerName': reviewerName,
        if (reviewerPhotoUrl != null) 'reviewerPhotoUrl': reviewerPhotoUrl,
        'rating': rating,
        'comment': comment,
        if (jobId != null) 'jobId': jobId,
        if (jobTitle != null) 'jobTitle': jobTitle,
      };

  /// Builds a [Review] from its doc id and (already Timestamp-normalised)
  /// data. Older docs lack the moderation fields and read as unflagged.
  factory Review.fromMap(String id, Map<String, dynamic> m) => Review(
        id: id,
        reviewerId: m['reviewerId'] as String? ?? '',
        reviewerName: m['reviewerName'] as String? ?? 'User',
        reviewerPhotoUrl: m['reviewerPhotoUrl'] as String?,
        rating: (m['rating'] as num?)?.toInt() ?? 0,
        comment: m['comment'] as String? ?? '',
        jobId: m['jobId'] as String?,
        jobTitle: m['jobTitle'] as String?,
        createdAt: m['createdAt'] as DateTime?,
        flagged: m['flagged'] as bool? ?? false,
        flagReason: m['flagReason'] as String?,
        flaggedByUid: m['flaggedByUid'] as String?,
        hidden: m['hidden'] as bool? ?? false,
      );
}
