import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/money.dart';
import '../../../core/util/plural.dart';
import '../../../core/util/time_ago.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/keyed_stream_builder.dart';
import '../../auth/domain/user_role.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../home/presentation/home_app_bar.dart';
import '../data/bid_repository.dart';
import '../data/bundle_bid_repository.dart';
import '../data/bundle_repository.dart';
import '../data/job_repository.dart';
import '../domain/bid.dart';
import '../domain/bundle.dart';
import '../domain/bundle_bid.dart';
import '../domain/job.dart';
import 'bundle/bundle_header.dart';
import 'widgets/job_card.dart';
import 'widgets/status_colors.dart';

/// What:   The My Jobs tab.
/// Input:  Signed-in user from AuthController; jobs, bundles and bids from their repositories.
/// Output: Requestor: posted jobs and bundles with a status filter. Provider: won jobs and pending bids.
class MyJobsScreen extends StatelessWidget {
  const MyJobsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = context.watch<AuthController>().user;
    final isProvider = user?.role == UserRole.provider;

    return Scaffold(
      appBar: const HomeAppBar(),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
              child: Text('My jobs', style: theme.textTheme.headlineMedium),
            ),
            Expanded(
              child: user == null
                  ? const EmptyState(
                      icon: Icons.assignment_outlined,
                      title: 'Nothing here yet',
                      message: 'Jobs you post will show up here.',
                    )
                  : isProvider
                      ? _ProviderJobs(uid: user.uid)
                      : _RequestorJobs(uid: user.uid),
            ),
          ],
        ),
      ),
    );
  }
}

class _RequestorJobs extends StatefulWidget {
  const _RequestorJobs({required this.uid});
  final String uid;

  @override
  State<_RequestorJobs> createState() => _RequestorJobsState();
}

class _RequestorJobsState extends State<_RequestorJobs> {
  JobStatus? _filter; // null means All

  @override
  Widget build(BuildContext context) {
    final jobs = context.read<JobRepository>();
    final bundles = context.read<BundleRepository>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Outside the builder so it survives the loading, empty and error states.
        _JobFilterBar(
          selected: _filter,
          onSelected: (f) => setState(() => _filter = f),
        ),
        Expanded(
          child: KeyedStreamBuilder<List<Job>>(
            cacheKey: widget.uid,
            create: () => jobs.watchMyJobs(widget.uid),
            builder: (context, jobSnapshot) {
              if (!jobSnapshot.hasData && !jobSnapshot.hasError) {
                return const Center(child: CircularProgressIndicator());
              }
              if (jobSnapshot.hasError) {
                return const EmptyState(
                  icon: Icons.error_outline,
                  title: "Couldn't load your jobs",
                  message: 'Please check your connection and try again.',
                );
              }
              final allJobs = jobSnapshot.data ?? [];
              if (allJobs.isEmpty) {
                return const EmptyState(
                  icon: Icons.assignment_outlined,
                  title: 'No jobs yet',
                  message: 'Post a job to start receiving bids.',
                );
              }
              return KeyedStreamBuilder<List<Bundle>>(
                cacheKey: widget.uid,
                create: () => bundles.watchMyBundles(widget.uid),
                builder: (context, bundleSnapshot) => _list(
                  context,
                  allJobs,
                  bundleSnapshot.data ?? const [],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Groups bundle tasks under their [bundles] card (a plain [JobCard] if it hasn't loaded).
  Widget _list(BuildContext context, List<Job> allJobs, List<Bundle> bundles) {
    final bundleById = {for (final b in bundles) b.id: b};
    final tasksByBundle = <String, List<Job>>{};
    final standalone = <Job>[];
    for (final job in allJobs) {
      final bundleId = job.bundleId;
      if (bundleId == null) {
        standalone.add(job);
      } else {
        tasksByBundle.putIfAbsent(bundleId, () => []).add(job);
      }
    }
    final filteredStandalone =
        standalone.where((j) => _filter == null || j.status == _filter).toList();

    final bundleCards = <Widget>[];
    for (final entry in tasksByBundle.entries) {
      final bundle = bundleById[entry.key];
      if (bundle == null) {
        for (final task in entry.value) {
          bundleCards
              .add(JobCard(job: task, onTap: () => context.push('/jobs/${task.id}')));
        }
        continue;
      }
      // Hide the card unless a task matches the filter; the progress line still counts all.
      final visibleTasks = _filter == null
          ? entry.value
          : entry.value.where((t) => t.status == _filter).toList();
      if (visibleTasks.isEmpty) continue;
      bundleCards.add(BundleJobsCard(
          bundle: bundle, allTasks: entry.value, tasks: visibleTasks));
    }

    final items = <Widget>[
      ...bundleCards,
      for (final job in filteredStandalone)
        JobCard(job: job, onTap: () => context.push('/jobs/${job.id}')),
    ];

    if (items.isEmpty) {
      return EmptyState(
        icon: Icons.filter_list_off,
        title: 'No ${_filter?.label.toLowerCase() ?? 'matching'} jobs',
        message: 'Try a different filter to see your other jobs.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, i) => items[i],
    );
  }
}

/// What:   Requestor's bundle card: title, progress line, status pill, one row per task.
/// Input:  [bundle]; [allTasks] for the progress line; [tasks] shown (filtered, default all).
/// Output: Tappable card that opens the bundle screen.
class BundleJobsCard extends StatelessWidget {
  const BundleJobsCard({
    super.key,
    required this.bundle,
    required this.allTasks,
    List<Job>? tasks,
  }) : tasks = tasks ?? allTasks;

  final Bundle bundle;
  final List<Job> allTasks;
  final List<Job> tasks;

  /// e.g. "4 tasks · 2 in progress · 1 done · 1 open".
  String get _progressLine {
    final counts = <JobStatus, int>{};
    for (final task in allTasks) {
      counts[task.status] = (counts[task.status] ?? 0) + 1;
    }
    final parts = [
      for (final status in [
        JobStatus.inProgress,
        JobStatus.completed,
        JobStatus.open,
        JobStatus.cancelled,
      ])
        if (counts[status] case final n? when n > 0)
          '$n ${switch (status) {
            JobStatus.inProgress => 'in progress',
            JobStatus.completed => 'done',
            JobStatus.open => 'open',
            JobStatus.cancelled => 'cancelled',
          }}',
    ];
    final noun = allTasks.length == 1 ? 'task' : 'tasks';
    return [
      '${allTasks.length} $noun',
      ...parts,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      onTap: () => context.push('/bundles/${bundle.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(bundle.title, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(
                      _progressLine,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              BundleStatusPill(bundle: bundle),
            ],
          ),
          const SizedBox(height: 12),
          for (final task in tasks)
            _BundleTaskRow(
              task: task,
              onTap: () => context.push('/jobs/${task.id}'),
            ),
        ],
      ),
    );
  }
}

// One task row in a [BundleJobsCard]; taps through to the task.
class _BundleTaskRow extends StatelessWidget {
  const _BundleTaskRow({required this.task, required this.onTap});
  final Job task;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(task.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium),
              ),
              const SizedBox(width: 8),
              PillBadge(
                  label: task.status.label,
                  color: jobStatusColor(context, task.status)),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right,
                  size: 18, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

// Horizontally scrolling single-select status filter; null means All.
class _JobFilterBar extends StatelessWidget {
  const _JobFilterBar({required this.selected, required this.onSelected});
  final JobStatus? selected;
  final ValueChanged<JobStatus?> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: Row(
        children: [
          for (final status in [null, ...JobStatus.values])
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(status?.label ?? 'All'),
                selected: selected == status,
                onSelected: (_) => onSelected(status),
              ),
            ),
        ],
      ),
    );
  }
}

// Provider view: won jobs, then pending per-job and package bids.
class _ProviderJobs extends StatelessWidget {
  const _ProviderJobs({required this.uid});
  final String uid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final jobs = context.read<JobRepository>();
    final bids = context.read<BidRepository>();
    final bundleBids = context.read<BundleBidRepository>();

    return KeyedStreamBuilder<List<Job>>(
      cacheKey: uid,
      create: () => jobs.watchAssignedJobs(uid),
      builder: (context, wonSnapshot) {
        return KeyedStreamBuilder<List<Bid>>(
          cacheKey: uid,
          create: () => bids.watchMyBids(uid),
          builder: (context, bidSnapshot) {
            return KeyedStreamBuilder<List<BundleBid>>(
              cacheKey: uid,
              create: () => bundleBids.watchMyBundleBids(uid),
              builder: (context, bundleBidSnapshot) {
                final loading =
                    (!wonSnapshot.hasData && !wonSnapshot.hasError) ||
                        (!bidSnapshot.hasData && !bidSnapshot.hasError) ||
                        (!bundleBidSnapshot.hasData &&
                            !bundleBidSnapshot.hasError);
                if (loading) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (wonSnapshot.hasError ||
                    bidSnapshot.hasError ||
                    bundleBidSnapshot.hasError) {
                  return const EmptyState(
                    icon: Icons.error_outline,
                    title: "Couldn't load your jobs",
                    message: 'Please check your connection and try again.',
                  );
                }
                final won = wonSnapshot.data ?? [];
                final pending = (bidSnapshot.data ?? [])
                    .where((b) => b.status == BidStatus.pending)
                    .toList();
                final pendingBundleBids = (bundleBidSnapshot.data ?? [])
                    .where((b) => b.status == BundleBidStatus.pending)
                    .toList();

                if (won.isEmpty &&
                    pending.isEmpty &&
                    pendingBundleBids.isEmpty) {
                  return const EmptyState(
                    icon: Icons.assignment_outlined,
                    title: 'Nothing here yet',
                    message: 'Jobs you bid on and win will show up here.',
                  );
                }

                return ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    if (won.isNotEmpty) ...[
                      Text('Won jobs', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 12),
                      for (final job in won)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: JobCard(
                            job: job,
                            onTap: () => context.push('/jobs/${job.id}'),
                          ),
                        ),
                      const SizedBox(height: 12),
                    ],
                    if (pending.isNotEmpty || pendingBundleBids.isNotEmpty) ...[
                      Text('Pending bids', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 12),
                      for (final bid in pending)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _PendingBidTile(bid: bid),
                        ),
                      for (final bid in pendingBundleBids)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _PendingBundleBidTile(bid: bid),
                        ),
                    ],
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

// A pending per-job bid; taps through to the job.
class _PendingBidTile extends StatelessWidget {
  const _PendingBidTile({required this.bid});
  final Bid bid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
        onTap: () => context.push('/jobs/${bid.jobId}'),
        child: Row(
          children: [
            Icon(Icons.gavel_rounded, color: context.fairbid.verified),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Scales down instead of wrapping mid-number at large text scales.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(formatRm(bid.amountSen),
                        maxLines: 1, style: theme.textTheme.titleLarge),
                  ),
                  Text('Bid ${timeAgo(bid.createdAt)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            PillBadge(
                label: bid.status.label, color: context.fairbid.warningText),
            const Icon(Icons.chevron_right),
          ],
        ),
      );
  }
}

// A pending package bid. Opens the covered task with the lowest bundleOrder
// (the taskPrices map has no ordering guarantee).
class _PendingBundleBidTile extends StatelessWidget {
  const _PendingBundleBidTile({required this.bid});
  final BundleBid bid;

  Future<void> _open(BuildContext context) async {
    try {
      final tasks =
          await context.read<JobRepository>().getBundleTasks(bid.bundleId);
      final covered = tasks.where((t) => bid.taskPrices.containsKey(t.id))
          .toList()
        ..sort((a, b) => (a.bundleOrder ?? 0).compareTo(b.bundleOrder ?? 0));
      final targetId =
          covered.isNotEmpty ? covered.first.id : bid.taskPrices.keys.first;
      if (!context.mounted) return;
      context.push('/jobs/$targetId');
    } catch (_) {
      if (!context.mounted) return;
      context.push('/jobs/${bid.taskPrices.keys.first}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final caption = [
      bid.bundleTitle,
      plural(bid.taskCount, 'task'),
      if (bid.bundlePriceSen != null) 'bundle price',
    ].join(' • ');
    return AppCard(
        onTap: () => _open(context),
        child: Row(
          children: [
            Icon(Icons.inventory_2_outlined, color: context.fairbid.verified),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(formatRm(bid.quotedTotalSen),
                        maxLines: 1, style: theme.textTheme.titleLarge),
                  ),
                  Text(
                    caption,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            PillBadge(
                label: bid.status.label, color: context.fairbid.warningText),
            const Icon(Icons.chevron_right),
          ],
        ),
      );
  }
}
