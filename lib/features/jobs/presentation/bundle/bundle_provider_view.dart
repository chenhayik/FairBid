import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/money.dart';
import '../../../../core/util/plural.dart';
import '../../../../core/util/service_categories.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../auth/domain/app_user.dart';
import '../../../auth/domain/user_role.dart';
import '../../domain/bundle.dart';
import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';
import '../bid/open_bid_sheet.dart';
import '../detail/photo_strip.dart';
import '../widgets/status_colors.dart';
import 'bundle_header.dart';

/// What:   A provider's read-only view of a bundle.
/// Input:  [bundle], [tasks] and the viewer's own [myBid] streams from BundleDetailScreen.
/// Output: Tasks, own bid card and a bid button; other providers' bids are never read.
class BundleProviderView extends StatelessWidget {
  const BundleProviderView({
    super.key,
    required this.bundle,
    required this.tasks,
    required this.myBid,
    required this.me,
    required this.onOpenTask,
  });

  final Bundle bundle;
  final Stream<List<Job>> tasks;

  final Stream<BundleBid?> myBid;
  final AppUser me;
  final ValueChanged<Job> onOpenTask;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<BundleBid?>(
      stream: myBid,
      builder: (context, bidSnap) {
        final mine = bidSnap.data;
        return Scaffold(
          appBar: AppBar(title: Text(bundle.title)),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                ..._header(context),
                if (mine != null) ...[
                  const SizedBox(height: 16),
                  _MyBidCard(bid: mine),
                ],
                const SizedBox(height: 20),
                StreamBuilder<List<Job>>(
                  // Keyed so it isn't remounted when the bid card appears.
                  key: const ValueKey('tasks'),
                  stream: tasks,
                  builder: (context, taskSnap) {
                    final list = taskSnap.data;
                    if (list == null) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final task in list) ...[
                          _TaskCard(
                            task: task,
                            onTap: () => onOpenTask(task),
                          ),
                          const SizedBox(height: 12),
                        ],
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          bottomNavigationBar: _bidBar(context, mine),
        );
      },
    );
  }

  List<Widget> _header(BuildContext context) {
    final theme = Theme.of(context);
    return [
      ...bundleSummary(context, bundle, counts: plural(bundle.taskCount, 'task')),
      if (bundle.photoUrls.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text('Photos', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        PhotoStrip(photoUrls: bundle.photoUrls),
      ],
    ];
  }

  /// The bid button; only for providers while bidding is open.
  Widget? _bidBar(BuildContext context, BundleBid? mine) {
    if (!bundle.biddingOpen || me.role != UserRole.provider) return null;
    final verified = me.verificationStatus == 'approved';
    final label = !verified
        ? 'Get verified to bid'
        : mine?.status == BundleBidStatus.pending
        ? 'Edit bundle bid'
        : 'Bid on this bundle';
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        border: Border(top: BorderSide(color: context.fairbid.borderSubtle)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
          child: PrimaryButton(
            label: label,
            onPressed: () => verified
                ? openBundleBidSheet(context, bundle.id, me)
                : context.push('/onboarding'),
          ),
        ),
      ),
    );
  }
}

// "Your bundle bid: RM x for N tasks" with its status.
class _MyBidCard extends StatelessWidget {
  const _MyBidCard({required this.bid});

  final BundleBid bid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Your bundle bid: ${formatRm(bid.quotedTotalSen)} for '
              '${plural(bid.taskCount, 'task')}',
              style: theme.textTheme.titleMedium,
            ),
          ),
          const SizedBox(width: 8),
          PillBadge(
            label: bid.status.label,
            color: bundleBidStatusColor(context, bid.status),
          ),
        ],
      ),
    );
  }
}

// One task of the bundle; taps through to its job detail.
class _TaskCard extends StatefulWidget {
  const _TaskCard({
    required this.task,
    required this.onTap,
  });

  final Job task;
  final VoidCallback onTap;

  @override
  State<_TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends State<_TaskCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final task = widget.task;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final budgetLabel = task.budget?.label;
    final licence = licenceNoticeFor(task.category);

    return AppCard(
      onTap: widget.onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(task.title, style: theme.textTheme.titleMedium),
          Text(
            budgetLabel == null
                ? task.category
                : '${task.category} • $budgetLabel',
            style: muted,
          ),
          if (task.description.trim().isNotEmpty) ...[
            TextButton(
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded ? 'Hide details' : 'Show details'),
            ),
            if (_expanded)
              Text(task.description, style: theme.textTheme.bodySmall),
          ],
          if (licence != null) ...[
            const SizedBox(height: 8),
            Text(licence, style: muted),
          ],
        ],
      ),
    );
  }
}
