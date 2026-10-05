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

/// Options that award the same providers to the same tasks, shown as one
/// card with joined labels (e.g. "Fewest providers · Recommended").
class MergedBundleOption {
  MergedBundleOption(this.option, this.labels);

  final BundleAwardOption option;
  final List<String> labels;

  String get combinedLabel => labels.join(' · ');

  /// True if the server's top pick is among the merged labels. Only that
  /// option gets the filled [PrimaryButton].
  bool get isRecommended => labels.any((l) => l == 'Recommended');
}

/// Merges options with identical awards into one [MergedBundleOption]
/// so there are no near-duplicate cards.
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
    } else {
      merged.add(MergedBundleOption(option, [option.label]));
    }
  }
  return merged;
}

/// One award option: cost, providers hired, and an Award button.
/// [primary] makes the button filled; the others are outlined.
class BundleOptionCard extends StatelessWidget {
  const BundleOptionCard({
    super.key,
    required this.merged,
    required this.tasks,
    required this.primary,
    required this.busy,
    required this.enabled,
    required this.onAward,
    this.onUse,
  });

  final MergedBundleOption merged;
  final List<Job> tasks;

  /// True when this card's Award button is the page's one filled button.
  final bool primary;
  final bool busy;

  /// False when the priced option is stale. Award is disabled until refresh.
  final bool enabled;
  final VoidCallback onAward;

  /// Fills the by-task picks from this option; hides the button when null.
  final VoidCallback? onUse;

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
    // The cheapest option's own total, so the premium can show as a %.
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
            // Label and amount get full-width lines so labels don't wrap.
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
              '${option.trustVisible ? '  •  Trust '
                        '${(option.weightedTrust / 10).round()}/100' : ''}',
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
                    // Provider and amount share a row; titles wrap below.
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
                  'when you award, you can post '
                  '${option.uncoveredTaskIds.length == 1 ? 'it' : 'them'} '
                  'separately or drop '
                  '${option.uncoveredTaskIds.length == 1 ? 'it' : 'them'}.',
                ),
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
            if (onUse != null) ...[
              const SizedBox(height: 8),
              OutlinedBusyButton(label: 'Use this option', onPressed: onUse),
            ],
          ],
        ),
      ),
    );
  }
}
