import 'package:flutter/material.dart';

import '../../../../core/widgets/app_widgets.dart';
import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';
import 'bundle_pick_logic.dart';
import 'bundle_pick_sheet.dart';
import 'bundle_task_section.dart';
import 'bundle_warning_banner.dart';

/// "Pick providers yourself": one row per open task with its pick.
/// Tap a row to see the bids for that task.
class BundlePickSection extends StatelessWidget {
  const BundlePickSection({
    super.key,
    required this.tasks,
    required this.bids,
    required this.picks,
    required this.onPick,
    required this.onOpenTask,
  });

  final List<Job> tasks;
  final List<BundleBid> bids;

  /// Task id -> provider id (null or missing: not awarded).
  final Map<String, String?> picks;

  /// Sets [providerId] (or null) as the pick for all of [taskIds].
  final void Function(List<String> taskIds, String? providerId) onPick;
  final ValueChanged<Job> onOpenTask;

  Future<void> _change(BuildContext context, Job task) async {
    final chosen = await showBundlePickSheet(
      context,
      title: 'Choose a provider for ${task.title}',
      taskIds: [task.id],
      bids: bids,
      currentProviderId: picks[task.id],
    );
    if (chosen == null) return;
    onPick([task.id], chosen == bundleNoProviderPick ? null : chosen);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hints = pickHints(picks, bids);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Pick providers yourself', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        for (final task in tasks) ...[
          _PickRow(
            task: task,
            bids: bids,
            providerId: picks[task.id],
            onChange: () => _change(context, task),
            onOpenTask: onOpenTask,
          ),
          const SizedBox(height: 12),
        ],
        for (final hint in hints)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: WarningBanner(hint),
          ),
      ],
    );
  }
}

class _PickRow extends StatelessWidget {
  const _PickRow({
    required this.task,
    required this.bids,
    required this.providerId,
    required this.onChange,
    required this.onOpenTask,
  });

  final Job task;
  final List<BundleBid> bids;
  final String? providerId;
  final VoidCallback onChange;
  final ValueChanged<Job> onOpenTask;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final biddable = bidsCoveringAll(bids, [task.id]).isNotEmpty;
    BundleBid? picked;
    for (final bid in bids) {
      if (bid.providerId == providerId) picked = bid;
    }

    final Widget pickLine;
    if (!biddable) {
      pickLine = Text('No bids on this task', style: muted);
    } else if (picked == null) {
      pickLine = Text('Not awarded', style: muted);
    } else {
      pickLine = PriceRow(
        name: picked.providerName,
        amountSen: bidPriceFor(picked, [task.id]),
        style: theme.textTheme.bodyMedium,
      );
    }

    return AppCard(
      onTap: biddable ? onChange : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        task.title,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Open task',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.chevron_right),
                      onPressed: () => onOpenTask(task),
                    ),
                  ],
                ),
                pickLine,
              ],
            ),
          ),
          if (biddable)
            TextButton(onPressed: onChange, child: const Text('Change')),
        ],
      ),
    );
  }
}
