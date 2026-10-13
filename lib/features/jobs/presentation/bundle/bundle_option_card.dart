import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/money.dart';
import '../../../../core/util/plural.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../domain/bundle_award.dart';
import '../../domain/job.dart';
import 'bundle_pick_logic.dart';
import 'bundle_task_section.dart';
import 'bundle_warning_banner.dart';

/// What:   Award options with identical awards, shown as one card with joined labels.
/// Input:  [option], [labels].
/// Output: [combinedLabel] and the recommended flag for the card.
class MergedBundleOption {
  MergedBundleOption(this.option, this.labels);

  final BundleAwardOption option;
  final List<String> labels;

  String get combinedLabel => labels.join(' · ');

  /// The server's top pick is among the labels; only it gets the filled button.
  bool get isRecommended => labels.any((l) => l == 'Recommended');
}

/// Merges options with identical awards, so there are no duplicate cards.
List<MergedBundleOption> mergeBundleOptions(List<BundleAwardOption> options) {
  final merged = <MergedBundleOption>[];
  for (final option in options) {
    final match = merged
        .where((c) => mapEquals(c.option.providerByTaskId, option.providerByTaskId))
        .firstOrNull;
    if (match != null) {
      match.labels.add(option.label);
    } else {
      merged.add(MergedBundleOption(option, [option.label]));
    }
  }
  return merged;
}

/// What:   One award option card: cost, providers hired, Award button.
/// Input:  [merged] from mergeBundleOptions(); [tasks] for titles; [primary] fills the button.
/// Output: Card calling [onAward], and [onUse] to fill the manual picks from it.
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

  final bool primary;
  final bool busy;

  /// False when the option is stale; Award stays disabled until refresh.
  final bool enabled;
  final VoidCallback onAward;

  /// Hides the "Use this option" button when null.
  final VoidCallback? onUse;

  String _titleFor(String taskId) => taskTitle(tasks, taskId);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final option = merged.option;
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
              SecondaryButton(
                label: 'Award this option',
                busy: busy,
                onPressed: enabled ? onAward : null,
              ),
            if (onUse != null) ...[
              const SizedBox(height: 8),
              SecondaryButton(label: 'Use this option', onPressed: onUse),
            ],
          ],
        ),
      ),
    );
  }
}
