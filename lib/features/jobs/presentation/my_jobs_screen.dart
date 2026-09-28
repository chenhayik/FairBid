import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/money.dart';
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
import 'widgets/job_card.dart';

/// The "My Jobs" tab. Requestors see the jobs they've posted; providers see
/// the jobs they've won and their pending bids.
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
              child: Text('My Jobs', style: theme.textTheme.headlineMedium),
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

/// The status filters offered on the requestor's job list - one per
/// [JobStatus], plus "All", so no job is ever hidden.
enum _JobFilter {
  all('All'),
  open('Open'),
  inProgress('In Progress'),
  completed('Completed'),
  cancelled('Cancelled');

  const _JobFilter(this.label);
  final String label;

  bool matches(JobStatus status) => switch (this) {
        _JobFilter.all => true,
        _JobFilter.open => status == JobStatus.open,
        _JobFilter.inProgress => status == JobStatus.inProgress,
        _JobFilter.completed => status == JobStatus.completed,
        _JobFilter.cancelled => status == JobStatus.cancelled,
      };
}

class _RequestorJobs extends StatefulWidget {
  const _RequestorJobs({required this.uid});
  final String uid;

  @override
  State<_RequestorJobs> createState() => _RequestorJobsState();
}

class _RequestorJobsState extends State<_RequestorJobs> {
  _JobFilter _filter = _JobFilter.all;

  @override
  Widget build(BuildContext context) {
    final jobs = context.read<JobRepository>();
    final bundles = context.read<BundleRepository>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Outside the builder: the filter row is part of the screen's chrome,
        // so it must survive the loading, empty and error states instead of
        // disappearing along with the list it controls.
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
              // A bundle's own tasks group under one card below, so this
              // stream only needs to exist once a job actually has a bundleId.
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

  /// Groups [allJobs] with a `bundleId` under their [bundles] card (falling
  /// back to a plain [JobCard] if unloaded); the status filter only narrows
  /// the standalone jobs, since a bundle's progress line covers its tasks.
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
        standalone.where((j) => _filter.matches(j.status)).toList();

    final items = <Widget>[
      for (final entry in tasksByBundle.entries)
        if (bundleById[entry.key] case final bundle?)
          BundleJobsCard(bundle: bundle, tasks: entry.value)
        else
          for (final task in entry.value)
            JobCard(job: task, onTap: () => context.push('/jobs/${task.id}')),
      for (final job in filteredStandalone)
        JobCard(job: job, onTap: () => context.push('/jobs/${job.id}')),
    ];

    if (items.isEmpty) {
      return EmptyState(
        icon: Icons.filter_list_off,
        title: 'No ${_filter.label.toLowerCase()} jobs',
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

/// One requestor bundle card: title (tapping opens the bundle screen), a
/// progress line from its tasks' statuses, status pill, and a task row each.
class BundleJobsCard extends StatelessWidget {
  const BundleJobsCard({super.key, required this.bundle, required this.tasks});
  final Bundle bundle;
  final List<Job> tasks;

  /// e.g. "4 tasks · 2 in progress · 1 done · 1 open".
  String get _progressLine {
    final counts = <JobStatus, int>{};
    for (final task in tasks) {
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
    final noun = tasks.length == 1 ? 'task' : 'tasks';
    return [
      '${tasks.length} $noun',
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
              PillBadge(
                  label: bundle.status.label, color: context.fairbid.verified),
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

/// One task inside a [BundleJobsCard]: its title and status, tapping through
/// to the task's own job detail screen.
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
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(task.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium),
            ),
            const SizedBox(width: 8),
            PillBadge(
                label: task.status.label,
                color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// Horizontally-scrollable single-select status filter for the job list.
class _JobFilterBar extends StatelessWidget {
  const _JobFilterBar({required this.selected, required this.onSelected});
  final _JobFilter selected;
  final ValueChanged<_JobFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: Row(
        children: [
          for (final f in _JobFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(f.label),
                selected: selected == f,
                onSelected: (_) => onSelected(f),
              ),
            ),
        ],
      ),
    );
  }
}

/// Provider view: the jobs they've won, then their still-pending bids (both
/// ordinary per-job bids and package bids on a bundle).
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
                      Text('Won Jobs', style: theme.textTheme.titleLarge),
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
                      Text('Pending Bids', style: theme.textTheme.titleLarge),
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

/// A provider's pending bid: amount + when, tappable through to the job.
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
                  Text(formatRm(bid.amountSen),
                      style: theme.textTheme.titleLarge),
                  Text('Bid ${timeAgo(bid.createdAt)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            PillBadge(
                label: bid.status.label, color: context.fairbid.warningText),
            const Icon(Icons.chevron_right),
          ],
        ),
      );
  }
}

/// A provider's pending package bid on a bundle: title, task count, quoted
/// total. No provider-facing bundle screen, so tapping opens the first task.
class _PendingBundleBidTile extends StatelessWidget {
  const _PendingBundleBidTile({required this.bid});
  final BundleBid bid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final amount = bid.bundlePriceSen != null
        ? '${formatRm(bid.quotedTotalSen)} (bundle price)'
        : formatRm(bid.quotedTotalSen);
    return AppCard(
        onTap: () => context.push('/jobs/${bid.taskPrices.keys.first}'),
        child: Row(
          children: [
            Icon(Icons.inventory_2_outlined, color: context.fairbid.verified),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(bid.bundleTitle, style: theme.textTheme.titleMedium),
                  Text(
                    '${bid.taskCount} task${bid.taskCount == 1 ? '' : 's'} • '
                    '$amount',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            PillBadge(
                label: bid.status.label, color: context.fairbid.warningText),
            const Icon(Icons.chevron_right),
          ],
        ),
      );
  }
}
