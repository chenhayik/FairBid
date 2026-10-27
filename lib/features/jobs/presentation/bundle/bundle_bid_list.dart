import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/user_chip.dart';
import '../../../profile/data/public_profile_repository.dart';
import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';
import '../widgets/status_colors.dart';
import 'bundle_pick_logic.dart';
import 'bundle_task_section.dart';

/// What:   Opens every package bid in a tall, scrollable sheet, Best Value first.
/// Input:  [bids] from BundleBidRepository.watchBundleBids(); [tasks] for titles;
///         PublicProfileRepository.fetchTrust() for current Trust Scores.
/// Output: One card per bid: price per task, bundle price, duration, message.
Future<void> showBundleBids(
  BuildContext context, {
  required List<BundleBid> bids,
  required List<Job> tasks,
}) {
  // Read here: the sheet's own context sits under the Navigator.
  final profiles = context.read<PublicProfileRepository>();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) =>
        _BundleBidsSheet(bids: bids, tasks: tasks, profiles: profiles),
  );
}

/// What:   The "All bids" sheet.
/// Input:  [bids], [tasks] and [profiles] for live Trust Scores.
/// Output: Bids ranked by rankBundleBidsByValue(); the top pending bid wears a "BEST VALUE" pill.
/// Notes:  Ranks on the bids' saved scores until the current ones load, and keeps them if that fails.
class _BundleBidsSheet extends StatefulWidget {
  const _BundleBidsSheet({
    required this.bids,
    required this.tasks,
    required this.profiles,
  });

  final List<BundleBid> bids;
  final List<Job> tasks;
  final PublicProfileRepository profiles;

  @override
  State<_BundleBidsSheet> createState() => _BundleBidsSheetState();
}

class _BundleBidsSheetState extends State<_BundleBidsSheet> {
  Map<String, ProviderTrust> _liveTrust = const {};

  @override
  void initState() {
    super.initState();
    widget.profiles
        .fetchTrust(widget.bids.map((b) => b.providerId))
        .then((trust) {
          if (mounted) setState(() => _liveTrust = trust);
        })
        .catchError((_) {
          // Keep the saved scores; never blank the list.
        });
  }

  @override
  Widget build(BuildContext context) {
    final ranked = rankBundleBidsByValue([
      for (final bid in widget.bids)
        if (_liveTrust[bid.providerId] case final t?)
          bid.withTrust(trustScore: t.trustScore, scoreVisible: t.scoreVisible)
        else
          bid,
    ]);
    // Best Value is only a pick among bids that can still win.
    final bestValueId = ranked
        .where((b) => b.status == BundleBidStatus.pending)
        .firstOrNull
        ?.providerId;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.9,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'All bids (${ranked.length})',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            'Best Value first: price (60%) and Trust Score (40%).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          for (final bid in ranked) ...[
            _BundleBidCard(
              bid: bid,
              titleFor: (id) => taskTitle(widget.tasks, id),
              isBestValue: bid.providerId == bestValueId,
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

/// What:   One provider's package bid as a card.
/// Input:  [bid] and [titleFor] (task id to title, via taskTitle in bundle_pick_logic.dart).
/// Output: Provider chip, status pill once decided, duration, per-task prices, bundle price and an expandable message.
class _BundleBidCard extends StatefulWidget {
  const _BundleBidCard({
    required this.bid,
    required this.titleFor,
    this.isBestValue = false,
  });

  final BundleBid bid;
  final String Function(String taskId) titleFor;

  /// The top pending bid by price and trust; wears a "BEST VALUE" pill.
  final bool isBestValue;

  @override
  State<_BundleBidCard> createState() => _BundleBidCardState();
}

class _BundleBidCardState extends State<_BundleBidCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bid = widget.bid;
    final trustPercent = (bid.providerTrustScore / 10).round();
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.isBestValue) ...[
            PillBadge(
              label: 'BEST VALUE',
              icon: Icons.workspace_premium_outlined,
              color: context.fairbid.successText,
            ),
            const SizedBox(height: 12),
          ],
          UserChip(
            uid: bid.providerId,
            name: bid.providerName,
            photoUrl: bid.providerPhotoUrl,
            nameStyle: theme.textTheme.titleMedium,
            subtitle: bid.providerScoreVisible
                ? 'Trust Score $trustPercent/100'
                : 'New provider, no score yet',
            subtitleMaxLines: 2,
          ),
          // Only once the award has moved the bid on; own line keeps the name full width.
          if (bid.status != BundleBidStatus.pending) ...[
            const SizedBox(height: 8),
            PillBadge(
              label: bid.status.label,
              color: bundleBidStatusColor(context, bid.status),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.schedule,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                bid.estimatedDuration,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final entry in bid.taskPrices.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: PriceRow(
                name: widget.titleFor(entry.key),
                amountSen: entry.value,
                style: theme.textTheme.bodyMedium,
                maxLines: 3,
              ),
            ),
          if (bid.bundlePriceSen != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: PriceRow(
                name: 'Bundle price (all tasks)',
                amountSen: bid.bundlePriceSen!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 3,
              ),
            ),
          if (bid.message.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              bid.message,
              maxLines: _expanded ? null : 2,
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            // Length is a cheap stand-in for measuring whether it overflows.
            if (bid.message.length > 140)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(_expanded ? 'Show less' : 'Show more'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
