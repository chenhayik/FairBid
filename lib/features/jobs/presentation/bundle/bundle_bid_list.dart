import 'package:flutter/material.dart';

import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/user_chip.dart';
import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';
import '../widgets/status_colors.dart';
import 'bundle_pick_logic.dart';
import 'bundle_task_section.dart';

/// What:   Opens every package bid in a tall, scrollable sheet.
/// Input:  [bids] from BundleBidRepository.watchBundleBids(); [tasks] for titles.
/// Output: One card per bid: price per task, bundle price, duration, message.
Future<void> showBundleBids(
  BuildContext context, {
  required List<BundleBid> bids,
  required List<Job> tasks,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.9,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'All bids (${bids.length})',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          for (final bid in bids) ...[
            _BundleBidCard(bid: bid, titleFor: (id) => taskTitle(tasks, id)),
            const SizedBox(height: 12),
          ],
        ],
      ),
    ),
  );
}

/// What:   One provider's package bid as a card.
/// Input:  [bid] and [titleFor] (task id to title, via taskTitle in bundle_pick_logic.dart).
/// Output: Provider chip, status pill once decided, duration, per-task prices, bundle price and an expandable message.
class _BundleBidCard extends StatefulWidget {
  const _BundleBidCard({required this.bid, required this.titleFor});

  final BundleBid bid;
  final String Function(String taskId) titleFor;

  @override
  State<_BundleBidCard> createState() => _BundleBidCardState();
}

class _BundleBidCardState extends State<_BundleBidCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bid = widget.bid;
    final trustPercent = (bid.providerTrustScore / 10).round();
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UserChip(
            uid: bid.providerId,
            name: bid.providerName,
            photoUrl: bid.providerPhotoUrl,
            nameStyle: theme.textTheme.titleMedium,
            subtitle: bid.providerScoreVisible
                ? 'Trust Score $trustPercent/100'
                : 'New provider, no score yet',
            subtitleMaxLines: 2,
          ),
          // Only once the award has moved the bid on; own line keeps the name full width.
          if (bid.status != BundleBidStatus.pending) ...[
            const SizedBox(height: 8),
            PillBadge(
              label: bid.status.label,
              color: bundleBidStatusColor(context, bid.status),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.schedule,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                bid.estimatedDuration,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final entry in bid.taskPrices.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: PriceRow(
                name: widget.titleFor(entry.key),
                amountSen: entry.value,
                style: theme.textTheme.bodyMedium,
                maxLines: 3,
              ),
            ),
          if (bid.bundlePriceSen != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: PriceRow(
                name: 'Bundle price (all tasks)',
                amountSen: bid.bundlePriceSen!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 3,
              ),
            ),
          if (bid.message.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              bid.message,
              maxLines: _expanded ? null : 2,
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            // Length is a cheap stand-in for measuring whether it overflows.
            if (bid.message.length > 140)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(_expanded ? 'Show less' : 'Show more'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
