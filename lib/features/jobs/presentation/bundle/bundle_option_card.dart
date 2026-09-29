import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/money.dart';
import '../../../../core/util/plural.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../domain/bundle_award.dart';
import '../../domain/job.dart';
import 'bundle_buttons.dart';
import 'bundle_task_section.dart';
import 'bundle_warning_banner.dart';

/// One or more [BundleAwardOption]s that award the exact same provider ->
/// task mapping, shown as a single card with their labels combined (e.g.
/// "Fewest providers · Recommended").
class MergedBundleOption {
  MergedBundleOption(this.option, this.labels, [List<String>? warnings])
      : warnings = warnings ?? option.warnings;

  final BundleAwardOption option;
  final List<String> labels;

  /// The union of every merged option's warnings, deduplicated - a plain
  /// `option.warnings` would silently drop a second option's warnings once
  /// two options merge into one card.
  final List<String> warnings;

  String get combinedLabel => labels.join(' · ');

  /// Whether the server's own top pick is among the merged labels - the one
  /// option per screen that gets the filled [PrimaryButton] treatment.
  bool get isRecommended => labels.any((l) => l == 'Recommended');
}

/// Groups options with identical awards under one [MergedBundleOption], so
/// two options that happen to hire the same providers for the same tasks
/// don't show up as two near-identical cards.
List<MergedBundleOption> mergeBundleOptions(List<BundleAwardOption> options) {
  final merged = <MergedBundleOption>[];
  for (final option in options) {
    MergedBundleOption? match;
    for (final candidate in merged) {
      if (mapEquals(candidate.option.providerByTaskId, option.providerByTaskId)) {
        match = candidate;
        break;
      }
    }
    if (match != null) {
      match.labels.add(option.label);
      for (final warning in option.warnings) {
        if (!match.warnings.contains(warning)) match.warnings.add(warning);
      }
    } else {
      merged.add(MergedBundleOption(option, [option.label], [...option.warnings]));
    }
  }
  return merged;
}

/// One award option (or several merged into it): what it costs, who it
/// hires, and an Award action. [primary] makes the Award button the one
/// filled [PrimaryButton] on the page; every other option gets an outlined
/// button instead, so only the recommended action competes for the eye.
class BundleOptionCard extends StatelessWidget {
  const BundleOptionCard({
    super.key,
    required this.merged,
    required this.tasks,
    required this.primary,
    required this.busy,
    required this.enabled,
    required this.onAward,
  });

  final MergedBundleOption merged;
  final List<Job> tasks;

  /// Whether this card's Award button is the page's one filled action.
  final bool primary;
  final bool busy;

  /// False while the priced option is stale (the bids moved on since it was
  /// worked out) - the Award button is disabled until a refresh.
  final bool enabled;
  final VoidCallback onAward;

  String _titleFor(String taskId) {
    for (final task in tasks) {
      if (task.id == taskId) return task.title;
    }
    return 'a task';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final option = merged.option;
    // The cheapest option's own total (totalSen - premiumSen), so the
    // premium can also be shown as a percentage of it.
    final cheapestSen = option.totalSen - option.premiumSen;
    final premiumPct = option.premiumSen > 0 && cheapestSen > 0
        ? option.premiumSen * 100 / cheapestSen
        : 0.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The label and amount each get their own full-width line rather
            // than sharing a Row - squeezed into half a Row, a merged label
            // like "Cheapest · Fewest providers" could wrap mid-word at
            // larger text scales.
            Text(merged.combinedLabel, style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(
              formatRm(option.totalSen),
              style: theme.textTheme.titleMedium?.copyWith(
                color: context.fairbid.verified,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${plural(option.providerCount, 'provider')}'
              '${option.premiumSen > 0 ? '  •  ${formatRm(option.premiumSen)} '
                        '(${premiumPct.toStringAsFixed(1)}%) more than the '
                        'cheapest' : ''}'
              '  •  Trust ${option.weightedTrust}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            for (final award in option.awards)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Provider + amount on their own row; the task titles
                    // wrap on a second line beneath instead of sharing one
                    // ellipsised line, where a long provider name could push
                    // every task title off screen.
                    PriceRow(
                      name: award.providerName,
                      amountSen: award.totalSen,
                      style: theme.textTheme.bodyMedium,
                    ),
                    Text(
                      award.taskAmountsSen.keys.map(_titleFor).join(', '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            if (option.uncoveredTaskIds.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: WarningBanner(
                  'Nobody bid on '
                  '${option.uncoveredTaskIds.map(_titleFor).join(', ')} - '
                  'awarding releases '
                  '${option.uncoveredTaskIds.length == 1 ? 'it' : 'them'} '
                  'back to ordinary bidding.',
                ),
              ),
            for (final warning in merged.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: WarningBanner(warning),
              ),
            const SizedBox(height: 12),
            if (primary)
              PrimaryButton(
                label: 'Award this option',
                busy: busy,
                onPressed: enabled ? onAward : null,
              )
            else
              OutlinedBusyButton(
                label: 'Award this option',
                busy: busy,
                onPressed: enabled ? onAward : null,
              ),
          ],
        ),
      ),
    );
  }
}
