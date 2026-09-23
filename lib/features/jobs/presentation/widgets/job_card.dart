import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/time_ago.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../domain/job.dart';

/// Compact job summary used in the feed, "Jobs near you" and My Jobs.
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

  /// Optional "2.5 km" shown on provider-facing lists.
  final String? distanceLabel;

  /// Whether this job is on the signed-in user's watchlist. Only meaningful
  /// when [onToggleSave] is set.
  final bool saved;

  /// Shows a bookmark toggle in the top pill row when set; cards that omit it
  /// (e.g. My Jobs) render unchanged.
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
                // Expanded + Wrap (not a plain Row of Flexibles) so a third
                // pill on a bundle task flows to a second line on a narrow
                // card instead of squeezing every pill's text down to a sliver.
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
                      job.status == JobStatus.open
                          ? PillBadge(
                              label: 'Open', color: context.fairbid.verified)
                          : PillBadge(
                              label: job.status.label,
                              color: theme.colorScheme.onSurfaceVariant),
                      if (job.bundleTaskCount != null &&
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
            Row(
              children: [
                if (budget != null)
                  Flexible(
                    child: Text(budget,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge
                            ?.copyWith(color: context.fairbid.verified)),
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${job.bidCount} bids  •  ${timeAgo(job.createdAt)}',
                    textAlign: TextAlign.end,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
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

/// Small "Closes in..." row shown on an open job's card once it has a
/// bidding deadline. Turns warning-coloured once under 24 hours remain.
class _DeadlineChip extends StatelessWidget {
  const _DeadlineChip({required this.deadline});
  final DateTime deadline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final urgent = deadline.difference(DateTime.now()).inHours < 24;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.timer_outlined,
            size: 14,
            color: urgent
                ? context.fairbid.warningText
                : theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          deadlineLabel(deadline),
          style: theme.textTheme.bodySmall?.copyWith(
              color: urgent
                  ? context.fairbid.warningText
                  : theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
