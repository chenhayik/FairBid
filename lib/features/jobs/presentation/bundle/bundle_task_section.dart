import 'package:flutter/material.dart';

import '../../../../core/util/money.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';
import '../widgets/status_colors.dart';

/// What:   Name-and-amount row; the name ellipsises, the RM figure never wraps.
/// Input:  [name], [amountSen]; [maxLines] lets a long task title wrap.
/// Output: Rendered row, used for every price line on the bundle screen.
class PriceRow extends StatelessWidget {
  const PriceRow({
    super.key,
    required this.name,
    required this.amountSen,
    this.style,
    this.maxLines = 1,
  });

  final String name;
  final int amountSen;
  final TextStyle? style;

  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            name,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        const SizedBox(width: 8),
        Text(formatRm(amountSen), style: style),
      ],
    );
  }
}

/// What:   The bundle's tasks (title, category) when there is nothing to pick yet.
/// Input:  [tasks] from JobRepository.watchBundleTasks(); [onOpenTask].
/// Output: One tappable card per task.
class BundleTaskList extends StatelessWidget {
  const BundleTaskList({
    super.key,
    required this.tasks,
    required this.onOpenTask,
  });

  final List<Job> tasks;
  final ValueChanged<Job> onOpenTask;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final task in tasks) ...[
          AppCard(
            onTap: () => onOpenTask(task),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(task.title, style: theme.textTheme.titleMedium),
                Text(
                  task.category,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

/// What:   The bundle's tasks once bidding is over.
/// Input:  [tasks]; [bids] to show a task's own price beside a package price.
/// Output: One card per task: price, category, status, winner.
class BundleTaskStatusList extends StatelessWidget {
  const BundleTaskStatusList({
    super.key,
    required this.tasks,
    required this.onOpenTask,
    this.bids = const [],
  });

  final List<Job> tasks;
  final ValueChanged<Job> onOpenTask;

  final List<BundleBid> bids;

  /// What:   The winner's price for [task] on its own.
  /// Output: Sen, or null when it equals the package split, or the task was released or had a price change.
  int? _alonePriceSen(Job task) {
    // Released tasks and price changes replace the package price.
    if (task.releasedAt != null || task.originalBidAmountSen != null) {
      return null;
    }
    final bid =
        bids.where((b) => b.providerId == task.acceptedProviderId).firstOrNull;
    final alone = bid?.priceFor(task.id);
    return alone != null && alone != task.acceptedBidAmountSen ? alone : null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final task in tasks) ...[
          AppCard(
            onTap: () => onOpenTask(task),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(task.title,
                          style: theme.textTheme.titleMedium),
                    ),
                    if (task.acceptedBidAmountSen != null) ...[
                      const SizedBox(width: 8),
                      Text(formatRm(task.acceptedBidAmountSen!),
                          style: theme.textTheme.titleMedium),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text.rich(
                  TextSpan(
                    style: muted,
                    children: [
                      TextSpan(text: '${task.category}  •  '),
                      TextSpan(
                        text: task.status.label,
                        style: TextStyle(
                          color: jobStatusColor(context, task.status),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextSpan(
                        text: task.acceptedProviderName != null
                            ? '  •  ${task.acceptedProviderName}'
                            : task.releasedAt != null
                            ? '  •  Released to ordinary bidding'
                            : '  •  Not awarded',
                      ),
                    ],
                  ),
                ),
                if (_alonePriceSen(task) case final alone?) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Package deal price. ${formatRm(alone)} if hired '
                    'for this task alone.',
                    style: muted,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}
