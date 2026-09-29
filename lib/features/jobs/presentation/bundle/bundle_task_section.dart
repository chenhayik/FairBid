import 'package:flutter/material.dart';

import '../../../../core/util/money.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';
import '../widgets/status_colors.dart';

/// A task's title and category, shared by both list variants below.
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
/// on the bundle screen (task bids, award rows, dropdown items).
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

/// The bundle's tasks while bidding is still open: each with a compact list
/// of who bid on it. The full detail (message, duration, all-or-nothing…)
/// lives in the Bids section instead, so this stays a quick scan.
class BundleOpenTaskList extends StatelessWidget {
  const BundleOpenTaskList({
    super.key,
    required this.tasks,
    required this.bids,
    required this.onOpenTask,
  });

  final List<Job> tasks;
  final List<BundleBid> bids;
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
                _taskHeader(context, task),
                const SizedBox(height: 8),
                for (final bid in bids.where((b) => b.coversTask(task.id)))
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: PriceRow(
                      name: bid.providerName,
                      amountSen: bid.priceFor(task.id)!,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                if (!bids.any((b) => b.coversTask(task.id)))
                  Text(
                    'No bids on this task',
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

/// The bundle's tasks once bidding no longer decides them (awarded,
/// cancelled or expired): each task's own status pill plus who won it, or
/// why it didn't get awarded.
class BundleTaskStatusList extends StatelessWidget {
  const BundleTaskStatusList({
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
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _taskHeader(context, task)),
                    const SizedBox(width: 8),
                    PillBadge(
                      label: task.status.label,
                      color: jobStatusColor(context, task.status),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (task.acceptedProviderName != null &&
                    task.acceptedBidAmountSen != null)
                  PriceRow(
                    name: task.acceptedProviderName!,
                    amountSen: task.acceptedBidAmountSen!,
                    style: theme.textTheme.bodyMedium,
                  )
                else
                  Text(
                    task.releasedAt != null
                        ? 'Released to ordinary bidding'
                        : 'Not awarded',
                    style: theme.textTheme.bodyMedium?.copyWith(
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
