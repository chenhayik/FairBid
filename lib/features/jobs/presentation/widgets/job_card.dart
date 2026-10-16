import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/plural.dart';
import '../../../../core/util/time_ago.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../domain/job.dart';
import 'status_colors.dart';

/// What:   Compact job summary card.
/// Input:  [job]; [distanceLabel]; [saved] and [onToggleSave] for the bookmark.
/// Output: Tappable card used in the feed, Jobs near you, My Jobs and Saved jobs.
class JobCard extends StatelessWidget {
  const JobCard({
    super.key,
    required this.job,
    this.onTap,
    this.distanceLabel,
    this.saved = false,
    this.onToggleSave,
  });

  final Job job;
  final VoidCallback? onTap;

  /// e.g. "2.5 km".
  final String? distanceLabel;
  final bool saved;

  /// Shows the bookmark toggle when set.
  final VoidCallback? onToggleSave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final budget = job.budget?.label;

    return AppCard(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Wrap, so a third pill flows to a second line instead of squeezing.
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      PillBadge(
                        label: job.category,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      PillBadge(
                        label: job.status.label,
                        color: jobStatusColor(context, job.status),
                      ),
                      if (job.isBiddingAsBundle &&
                          job.bundleTaskCount != null &&
                          job.bundleTaskCount! > 1)
                        PillBadge(
                          label: 'Part of a ${job.bundleTaskCount}-task '
                              'bundle',
                          color: context.fairbid.verified,
                        ),
                    ],
                  ),
                ),
                if (onToggleSave != null)
                  IconButton(
                    tooltip: saved ? 'Saved' : 'Save job',
                    icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border),
                    color: saved
                        ? context.fairbid.verified
                        : theme.colorScheme.onSurfaceVariant,
                    onPressed: onToggleSave,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(job.title,
                style: theme.textTheme.titleLarge,
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 6),
            Text(
              job.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.location_on_outlined,
                    size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    [job.location.address, distanceLabel]
                        .where((s) => s != null && s.isNotEmpty)
                        .join('  •  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Own line: sharing a row with the bid count clips it.
            if (budget != null) ...[
              Text(budget,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: context.fairbid.verified)),
              const SizedBox(height: 4),
            ],
            Text(
              '${plural(job.bidCount, 'bid')}  •  ${timeAgo(job.createdAt)}',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (job.status == JobStatus.open && job.deadline != null) ...[
              const SizedBox(height: 6),
              _DeadlineChip(deadline: job.deadline!),
            ],
          ],
        ),
      );
  }
}

/// What:   "Closes in..." row for an open job.
/// Input:  [deadline]; text from deadlineLabel().
/// Output: Timer icon and label, warning-coloured under 24 hours.
class _DeadlineChip extends StatelessWidget {
  const _DeadlineChip({required this.deadline});
  final DateTime deadline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final urgent = deadline.difference(DateTime.now()).inHours < 24;
    final color = urgent
        ? context.fairbid.warningText
        : theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.timer_outlined, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          deadlineLabel(deadline),
          style: theme.textTheme.bodySmall?.copyWith(color: color),
        ),
      ],
    );
  }
}
