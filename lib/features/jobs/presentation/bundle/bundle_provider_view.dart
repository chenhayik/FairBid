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

/// A provider's (or any non-owner's) read-only view of a bundle: what it is,
/// every task in it, their own bundle bid if they have one, and one bottom
/// action to bid. It never reads other providers' bids - rules only let the
/// owner do that - so there is no bids list, award or cancel here.
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

  /// The viewer's own bid on [bundle] - the only bid they may read.
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
                  // Keyed so it isn't remounted (and the one-shot task
                  // stream re-listened) when the bid card above appears.
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
                            allTasks: list,
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
    final deadline = bundleDeadlineText(bundle);
    return [
      Text(
        plural(bundle.taskCount, 'task'),
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      if (bundle.description.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(bundle.description, style: theme.textTheme.bodyMedium),
      ],
      if (deadline != null) ...[
        const SizedBox(height: 8),
        Text(
          deadline,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: BundleStatusPill(bundle: bundle),
      ),
      if (bundle.photoUrls.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text('Photos', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        PhotoStrip(photoUrls: bundle.photoUrls),
      ],
    ];
  }

  /// The one primary action, shown only while bidding is open and only to
  /// providers - the same choice job detail's bottom bar makes for a task.
  Widget? _bidBar(BuildContext context, BundleBid? mine) {
    if (!bundle.biddingOpen || me.role != UserRole.provider) return null;
    final verified = me.verificationStatus == 'approved';
    final label = !verified
        ? 'Get verified to bid'
        : mine == null
        ? 'Bid on this bundle'
        : 'Edit bundle bid';
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

/// "Your bundle bid: RM x for N tasks" with its status.
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

/// One task of the bundle: what it is, how it fits with the others, and a tap
/// through to its job detail.
class _TaskCard extends StatefulWidget {
  const _TaskCard({
    required this.task,
    required this.allTasks,
    required this.onTap,
  });

  final Job task;
  final List<Job> allTasks;
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
    final startsAfter = widget.allTasks
        .where((t) => t.id == task.startsAfterJobId)
        .firstOrNull;
    final linked = task.lotId == null
        ? const <Job>[]
        : widget.allTasks
              .where((t) => t.lotId == task.lotId && t.id != task.id)
              .toList();
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
          if (startsAfter != null) ...[
            const SizedBox(height: 8),
            Text('Starts after ${startsAfter.title}', style: muted),
          ],
          if (linked.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Linked with ${linked.map((t) => t.title).join(', ')} — '
              'linked tasks go to the same provider.',
              style: muted,
            ),
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
