import 'package:flutter/material.dart';

import '../../../../core/widgets/app_widgets.dart';
import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';
import 'bundle_pick_logic.dart';
import 'bundle_pick_sheet.dart';
import 'bundle_task_section.dart';
import 'bundle_warning_banner.dart';

/// What:   "Pick providers yourself": one row per task with its pick.
/// Input:  [tasks], [bids] and [picks] from BundleDetailScreen.
/// Output: Rows that open a bid sheet per task; [onPick] reports the choice.
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
  final void Function(String taskId, String? providerId) onPick;
  final ValueChanged<Job> onOpenTask;

  /// What:   Opens the provider sheet for one task.
  /// Output: Calls [onPick] with the chosen provider id, or null for "Don't award".
  Future<void> _change(BuildContext context, Job task) async {
    final chosen = await showBundlePickSheet(
      context,
      title: 'Choose a provider for ${task.title}',
      taskId: task.id,
      bids: bids,
      currentProviderId: picks[task.id],
    );
    if (chosen == null) return;
    onPick(task.id, chosen == bundleNoProviderPick ? null : chosen);
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

/// What:   One task row in the pick list.
/// Input:  [task], [bids], [providerId] (current pick).
/// Output: Title with open-task button, then the pick line (provider and price, "Not awarded" or "No bids on this task") and Change.
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
    final biddable = bidsCoveringTask(bids, task.id).isNotEmpty;
    final picked = bids.where((b) => b.providerId == providerId).lastOrNull;

    final Widget pickLine;
    if (!biddable) {
      pickLine = Text('No bids on this task', style: muted);
    } else if (picked == null) {
      pickLine = Text('Not awarded', style: muted);
    } else {
      pickLine = PriceRow(
        name: picked.providerName,
        amountSen: picked.priceFor(task.id) ?? 0,
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
