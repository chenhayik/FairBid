import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/money.dart';
import '../../../../core/util/plural.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/user_chip.dart';
import '../../domain/bundle_award.dart';
import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';
import 'bundle_pick_logic.dart';
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

/// What:   Award option cards with the Best Value card first.
/// Input:  [merged] from mergeBundleOptions().
/// Output: Same cards; the Best Value one moved to the top, the rest in server order.
List<MergedBundleOption> bestValueFirst(List<MergedBundleOption> merged) => [
  ...merged.where((m) => m.isBestValue),
  ...merged.where((m) => !m.isBestValue),
];

/// What:   One award option card: total, premium, providers, Trust Score, Award button.
/// Input:  [merged] from mergeBundleOptions(); [tasks] for titles; [bids] for photos and bundle savings; [primary] fills the button.
/// Output: Card with a profile chip per provider, calling [onAward], and [onUse] to fill the manual picks from it.
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
    this.bids = const [],
  });

  final MergedBundleOption merged;
  final List<Job> tasks;

  /// The bundle's bids; a provider with none here shows no photo or saving.
  final List<BundleBid> bids;

  final bool primary;
  final bool busy;

  /// False when the option is stale; Award stays disabled until refresh.
  final bool enabled;
  final VoidCallback onAward;

  /// Hides the "Use this option" button when null.
  final VoidCallback? onUse;

  String _titleFor(String taskId) => taskTitle(tasks, taskId);

  /// What:   One winning provider's row.
  /// Input:  [award]; its bid from [bids] for the photo and single prices.
  /// Output: Profile chip, amount and, when lower than single prices, the bundle-deal saving.
  Widget _awardRow(BuildContext context, BundleAwardItem award) {
    final theme = Theme.of(context);
    final bid = bids.where((b) => b.providerId == award.providerId).firstOrNull;
    final saving = bid == null
        ? 0
        : bundleSavingSen(bid, award.taskAmountsSen);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: UserChip(
                  uid: award.providerId,
                  name: award.providerName,
                  photoUrl: bid?.providerPhotoUrl,
                  subtitle: award.taskAmountsSen.keys.map(_titleFor).join(', '),
                  subtitleMaxLines: 2,
                  nameStyle: theme.textTheme.bodyMedium,
                  // The amount sits on the right; a chevron would crowd small screens.
                  showChevron: false,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatRm(award.totalSen),
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
          if (saving > 0)
            Text(
              'Bundle deal: saves ${formatRm(saving)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: context.fairbid.verified,
              ),
            ),
        ],
      ),
    );
  }

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
            for (final award in option.awards) _awardRow(context, award),
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
