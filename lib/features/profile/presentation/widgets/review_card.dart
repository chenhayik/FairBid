import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/time_ago.dart';
import '../../../../core/widgets/user_chip.dart';
import '../../domain/review.dart';

/// What:   One review: reviewer name, time, stars and comment.
/// Input:  [review]; optional [onFlag].
/// Output: Unframed column so several stack in one card with dividers; a Report action when [onFlag] is set.
class ReviewCard extends StatelessWidget {
  const ReviewCard({super.key, required this.review, this.onFlag});

  final Review review;

  /// Set on the owner's own profile to flag an unfair review.
  final VoidCallback? onFlag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              // An empty reviewerId is malformed legacy data: plain text, not a link.
              child: review.reviewerId.isEmpty
                  ? Text(
                      review.reviewerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge,
                    )
                  : UserChip(
                      uid: review.reviewerId,
                      name: review.reviewerName,
                      showAvatar: false,
                      showChevron: false,
                      nameStyle: theme.textTheme.labelLarge,
                    ),
            ),
            const SizedBox(width: 8),
            Text(timeAgo(review.createdAt),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            if (onFlag != null && !review.flagged) ...[
              const SizedBox(width: 4),
              Semantics(
                button: true,
                label: 'Report review',
                child: InkWell(
                  onTap: onFlag,
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    constraints:
                        const BoxConstraints(minWidth: 48, minHeight: 48),
                    alignment: Alignment.center,
                    child: Icon(Icons.flag_outlined,
                        size: 16, color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            ] else if (review.flagged) ...[
              const SizedBox(width: 4),
              Icon(Icons.flag, size: 16, color: context.fairbid.warningText),
            ],
          ],
        ),
        const SizedBox(height: 6),
        StarRow(rating: review.rating),
        if (review.comment.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            '"${review.comment}"',
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ],
    );
  }
}

/// What:   Five stars, filled up to [rating] (1-5).
/// Input:  [rating].
/// Output: Gold filled and outlined stars.
class StarRow extends StatelessWidget {
  const StarRow({super.key, required this.rating});

  final int rating;

  @override
  Widget build(BuildContext context) {
    final gold = context.fairbid.warningText;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Icon(
            i <= rating ? Icons.star : Icons.star_border,
            size: 16,
            color: gold,
          ),
      ],
    );
  }
}
