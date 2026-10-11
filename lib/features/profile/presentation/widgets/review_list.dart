import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/keyed_stream_builder.dart';
import '../../data/review_repository.dart';
import '../../domain/review.dart';
import 'review_card.dart';

/// What:   Card of a user's 3 newest reviews with its own header, error and empty states.
/// Input:  [uid]; ReviewRepository.watchReviews() (review_repository.dart); [header] widget.
/// Output: ReviewCards with dividers; a Report action when [onFlag] is set; "See all" when [seeAllCount] exceeds those shown.
class ReviewList extends StatelessWidget {
  const ReviewList({
    super.key,
    required this.uid,
    required this.header,
    this.onFlag,
    this.seeAllCount,
  });

  final String uid;
  final Widget header;

  /// Set on the owner's own profile to flag an unfair review.
  final void Function(Review review)? onFlag;

  /// Total review count; a "See all" button shows when it exceeds the reviews listed.
  final int? seeAllCount;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<ReviewRepository>();
    return AppCard(
      child: KeyedStreamBuilder<List<Review>>(
        cacheKey: uid,
        create: () => repo.watchReviews(uid, limit: 3),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const EmptyState(
              icon: Icons.error_outline,
              title: "Couldn't load reviews",
              message: 'Please check your connection and try again.',
            );
          }
          final items = snapshot.data ?? const <Review>[];
          final total = seeAllCount;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              const SizedBox(height: 12),
              if (items.isEmpty)
                const EmptyState(
                  icon: Icons.star_border_rounded,
                  title: 'No reviews yet',
                  message: 'Reviews from completed jobs will appear here.',
                )
              else ...[
                for (final (i, review) in items.indexed) ...[
                  if (i > 0) const Divider(height: 24),
                  ReviewCard(
                    review: review,
                    onFlag: onFlag == null ? null : () => onFlag!(review),
                  ),
                ],
                if (total != null && total > items.length) ...[
                  const SizedBox(height: 12),
                  Center(
                    child: TextButton(
                      onPressed: () => context.push('/users/$uid/reviews'),
                      child: Text('See all $total reviews'),
                    ),
                  ),
                ],
              ],
            ],
          );
        },
      ),
    );
  }
}
