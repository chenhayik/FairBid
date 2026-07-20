import '../../profile/domain/review.dart';

/// One flagged review in the admin moderation queue, paired with the profile
/// it sits on — a collection-group query returns review docs whose parent
/// (the reviewee) would otherwise be lost.
class FlaggedReview {
  const FlaggedReview({required this.revieweeId, required this.review});

  final String revieweeId;
  final Review review;
}
