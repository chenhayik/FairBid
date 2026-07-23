import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/time_ago.dart';
import '../../domain/review.dart';

/// A single review as it appears inside the profile's Reviews card: the
/// reviewer's name, a relative timestamp, a star row and the comment. Rendered
/// without its own card surface so several stack inside one [AppCard] with
/// dividers between them (per the profile mock).
class ReviewCard extends StatelessWidget {
  const ReviewCard({super.key, required this.review, this.onFlag});

  final Review review;

  /// When set, a small "Report" action appears — used on the owner's own
  /// profile to flag an unfair review for admin moderation. Null elsewhere.
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
              child: Text(
                review.reviewerName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge,
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
              Icon(Icons.flag, size: 16, color: context.fairbid.warning),
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

/// A row of five stars, filled up to [rating] (1–5) with the brand's warning
/// gold, the rest outlined. Used in reviews and average-rating summaries.
class StarRow extends StatelessWidget {
  const StarRow({super.key, required this.rating, this.size = 16});

  final int rating;
  final double size;

  @override
  Widget build(BuildContext context) {
    final gold = context.fairbid.warning;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Icon(
            i <= rating ? Icons.star : Icons.star_border,
            size: size,
            color: gold,
          ),
      ],
    );
  }
}
