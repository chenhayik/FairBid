import 'package:flutter/material.dart';

import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/user_chip.dart';
import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';
import '../widgets/status_colors.dart';
import 'bundle_task_section.dart';

/// The "Bids" section: one card per package bid, with enough detail (price
/// per task, duration, message, all-or-nothing) that the per-task summary
/// above it can stay compact.
class BundleBidList extends StatelessWidget {
  const BundleBidList({super.key, required this.bids, required this.tasks});

  final List<BundleBid> bids;
  final List<Job> tasks;

  String _titleFor(String taskId) {
    for (final task in tasks) {
      if (task.id == taskId) return task.title;
    }
    return 'a task';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (bids.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Bids', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        for (final bid in bids) ...[
          _BundleBidCard(bid: bid, titleFor: _titleFor),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

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
          // Meaningless while every bid is still pending (nothing has been
          // decided), so it only appears once the award has moved this bid on.
          // Its own line keeps the name and score at full width.
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
          if (bid.allOrNothing) ...[
            const SizedBox(height: 8),
            Text(
              'All or nothing - the provider only accepts winning every '
              'task in this bid, never a subset.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
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
            // A short, one-line message never actually overflows 2 lines, so
            // the toggle only shows once it's long enough that it plausibly
            // does - simpler than measuring the laid-out text.
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
