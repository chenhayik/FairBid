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
/// Input:  [option], [labels] and, optionally, the option [keys] they came from.
/// Output: [combinedLabel], the best-value flag and the explanation line for the card.
class MergedBundleOption {
  MergedBundleOption(this.option, this.labels, [List<String>? keys])
    : keys = keys ?? [option.key];

  final BundleAwardOption option;
  final List<String> labels;

  /// Server keys of every option merged into this card.
  final List<String> keys;

  /// What:   Joined option labels.
  String get combinedLabel => labels.join(' · ');

  /// What:   Whether the server's Best Value option is among the keys.
  /// Notes:  Only the Best Value card gets the filled button.
  bool get isBestValue => keys.contains('bestValue');

  /// What:   One line saying what this card optimises.
  /// Output: The line for the highest-priority key (bestValue, cheapest, fewest), or null.
  String? get explanation {
    if (keys.contains('bestValue')) {
      return 'Balances total price (60%) and Trust Score (40%), the same as '
          'single jobs.';
    }
    if (keys.contains('cheapest')) return 'The cheapest way to cover every task.';
    if (keys.contains('fewest')) return 'Fewest separate providers to deal with.';
    return null;
  }
}

/// What:   Merges options with identical awards, so there are no duplicate cards.
/// Input:  [options] from BundleRepository.previewAward().
/// Output: One MergedBundleOption per distinct award (compared by providerByTaskId), labels joined.
List<MergedBundleOption> mergeBundleOptions(List<BundleAwardOption> options) {
  final merged = <MergedBundleOption>[];
  for (final option in options) {
    final match = merged
        .where((c) => mapEquals(c.option.providerByTaskId, option.providerByTaskId))
        .firstOrNull;
    if (match != null) {
      match.labels.add(option.label);
      match.keys.add(option.key);
    } else {
      merged.add(MergedBundleOption(option, [option.label], [option.key]));
    }
  }
  return merged;
}

/// What:   One award option card: total, premium, providers, Trust Score, Award button.
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
    final explanation = merged.explanation;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(merged.combinedLabel, style: theme.textTheme.titleMedium),
            if (explanation != null)
              Text(
                explanation,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
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
              '  •  ${option.premiumSen > 0 ? '+${formatRm(option.premiumSen)} '
                        'vs lowest' : 'Lowest'}'
              '  •  ${option.trustVisible ? 'Trust '
                        '${(option.weightedTrust / 10).round()}/100' : 'Includes a new provider'}',
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
