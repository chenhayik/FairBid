import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/time_ago.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../profile/presentation/widgets/review_card.dart';
import '../data/moderation_repository.dart';
import '../domain/flagged_review.dart';

/// Admin Home › Reviews tab: every review reported as unfair/abusive. Each is
/// small enough to moderate inline — Hide removes it from public display and
/// recomputes the reviewee's Trust Score without it; Keep clears the flag.
class ModerationQueueScreen extends StatefulWidget {
  const ModerationQueueScreen({super.key});

  @override
  State<ModerationQueueScreen> createState() => _ModerationQueueScreenState();
}

class _ModerationQueueScreenState extends State<ModerationQueueScreen> {
  // Cached so rebuilds don't resubscribe to Firestore.
  late final Stream<List<FlaggedReview>> _flagged;

  /// The review with a ruling call in flight, disabling its buttons.
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _flagged =
        context.read<ModerationRepository>().watchFlaggedReviews();
  }

  Future<void> _moderate(FlaggedReview item, {required bool hide}) async {
    final repo = context.read<ModerationRepository>();
    setState(() => _busyId = item.review.id);
    try {
      await repo.moderateReview(
        revieweeId: item.revieweeId,
        reviewId: item.review.id,
        hide: hide,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(hide
              ? 'Review hidden — the Trust Score has been recomputed.'
              : 'Review kept — the flag was cleared.')));
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              e.message ?? 'Could not save the ruling. Please try again.')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not save the ruling. Please try again.')));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<List<FlaggedReview>>(
      stream: _flagged,
      builder: (context, snapshot) {
        final items = snapshot.data;
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('Review Moderation', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 4),
            Text('Rule on reviews reported as unfair or abusive.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 24),
            StatCard(
              label: 'Flagged Reviews',
              value: items == null ? '—' : '${items.length}',
              icon: Icons.flag_outlined,
            ),
            const SizedBox(height: 24),
            if (snapshot.hasError)
              const AppCard(
                child: EmptyState(
                  icon: Icons.error_outline,
                  title: 'Couldn\'t load flagged reviews',
                  message: 'Check your connection and try again.',
                ),
              )
            else if (items == null)
              const Padding(
                padding: EdgeInsets.only(top: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (items.isEmpty)
              const AppCard(
                child: EmptyState(
                  icon: Icons.rate_review_outlined,
                  title: 'Nothing to moderate',
                  message: 'When someone reports a review on their profile, '
                      'it will appear here for a ruling.',
                ),
              )
            else
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _FlaggedReviewCard(
                    item: item,
                    busy: _busyId == item.review.id,
                    onHide: () => _moderate(item, hide: true),
                    onKeep: () => _moderate(item, hide: false),
                  ),
                ),
          ],
        );
      },
    );
  }
}

/// One flagged review, moderated inline: the review itself, the reporter's
/// reason, and the Hide / Keep ruling buttons.
class _FlaggedReviewCard extends StatelessWidget {
  const _FlaggedReviewCard({
    required this.item,
    required this.busy,
    required this.onHide,
    required this.onKeep,
  });

  final FlaggedReview item;
  final bool busy;
  final VoidCallback onHide;
  final VoidCallback onKeep;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final danger = context.fairbid.danger;
    final review = item.review;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(review.reviewerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              Text(timeAgo(review.createdAt),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 4),
          StarRow(rating: review.rating),
          if (review.jobTitle != null) ...[
            const SizedBox(height: 4),
            Text('Job: ${review.jobTitle}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
          if (review.comment.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('"${review.comment}"', style: theme.textTheme.bodyMedium),
          ],
          const SizedBox(height: 12),
          InfoBanner(
            icon: Icons.flag_outlined,
            color: context.fairbid.warningText,
            background: context.fairbid.warning.withValues(alpha: 0.12),
            title: 'Reported',
            body: review.flagReason?.trim().isNotEmpty == true
                ? review.flagReason!
                : 'No reason given.',
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : onHide,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: danger,
                    side: BorderSide(color: danger),
                  ),
                  icon: const Icon(Icons.visibility_off_outlined, size: 18),
                  label: const Text('Hide'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: PrimaryButton(
                  label: 'Keep',
                  busy: busy,
                  trailingIcon: Icons.check_rounded,
                  onPressed: onKeep,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
