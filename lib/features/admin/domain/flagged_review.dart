import '../../profile/domain/review.dart';

/// What:   One flagged review in the moderation queue, with the reviewee it sits on.
/// Input:  Collection-group query in FirestoreModerationRepository.watchFlaggedReviews().
/// Output: [revieweeId] (otherwise lost from the doc) plus the [review].
class FlaggedReview {
  const FlaggedReview({required this.revieweeId, required this.review});

  final String revieweeId;
  final Review review;
}
