import 'package:flutter/material.dart';

import '../../../../core/util/money.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';
import '../widgets/status_colors.dart';

/// A task's title and category, used by the task status list below.
Widget _taskHeader(BuildContext context, Job task) {
  final theme = Theme.of(context);
  return Column(
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
  );
}

/// A name-and-amount row: the name on the left, ellipsised, and the RM
/// figure fixed on the right so it never wraps - used for every price line
/// on the bundle screen (pick rows, award rows).
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

  /// How many lines [name] may wrap to before ellipsising - 2 for a task
  /// title that would otherwise cut off, 1 (the default) everywhere else.
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

/// Just the bundle's tasks (title and category), for an open bundle with
/// nothing to pick from yet - no bids, or bidding has closed.
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final task in tasks) ...[
          AppCard(
            onTap: () => onOpenTask(task),
            child: _taskHeader(context, task),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

/// The bundle's tasks once bidding is over: one compact card per task with
/// its price, category, status and winner.
class BundleTaskStatusList extends StatelessWidget {
  const BundleTaskStatusList({
    super.key,
    required this.tasks,
    required this.onOpenTask,
    this.bids = const [],
  });

  final List<Job> tasks;
  final ValueChanged<Job> onOpenTask;

  /// The bundle's bids, to show a task's own price beside a package price.
  final List<BundleBid> bids;

  /// The winner's price for [task] if hired for it alone, when that differs
  /// from what the package deal split it to.
  int? _alonePriceSen(Job task) {
    // Released tasks are won by ordinary bids, and a later price change
    // replaces the package price, so neither gets the note.
    if (task.releasedAt != null || task.originalBidAmountSen != null) {
      return null;
    }
    for (final bid in bids) {
      if (bid.providerId != task.acceptedProviderId) continue;
      final alone = bid.priceFor(task.id);
      return alone != null && alone != task.acceptedBidAmountSen ? alone : null;
    }
    return null;
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
                // Category, status and winner share one line.
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
