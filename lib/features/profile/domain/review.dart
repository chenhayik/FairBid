/// What:   A review left on a user's profile after a completed job.
/// Input:  `users/{revieweeId}/reviews/{reviewId}` via reviewFromDoc(); the reviewee is the path, not a field.
/// Output: Immutable model; [toMap] writes only the client-set fields.
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
    this.hidden = false,
  });

  final String id;
  final String reviewerId;
  final String reviewerName;

  /// The reviewer's photo at review time, denormalised like [reviewerName]; null if none.
  final String? reviewerPhotoUrl;

  /// Stars, 1-5.
  final int rating;
  final String comment;
  final String? jobId;
  final String? jobTitle;
  final DateTime? createdAt;

  /// Moderation: the reviewee flags it, then an admin hides it (reversing its Trust Score effect) or clears the flag.
  final bool flagged;
  final String? flagReason;
  final bool hidden;

  /// Client-written fields; `createdAt` is a server timestamp and moderation fields are written later.
  Map<String, dynamic> toMap() => {
        'reviewerId': reviewerId,
        'reviewerName': reviewerName,
        if (reviewerPhotoUrl != null) 'reviewerPhotoUrl': reviewerPhotoUrl,
        'rating': rating,
        'comment': comment,
        if (jobId != null) 'jobId': jobId,
        if (jobTitle != null) 'jobTitle': jobTitle,
      };

  /// Builds from the doc id and Timestamp-normalised data; older docs read as unflagged.
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
        hidden: m['hidden'] as bool? ?? false,
      );
}
