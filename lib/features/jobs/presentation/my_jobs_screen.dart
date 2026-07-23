import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/money.dart';
import '../../../core/util/time_ago.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../auth/domain/user_role.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../home/presentation/home_app_bar.dart';
import '../data/bid_repository.dart';
import '../data/job_repository.dart';
import '../domain/bid.dart';
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

/// The status filters offered on the requestor's job list — one per
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
    final repo = context.read<JobRepository>();
    return StreamBuilder<List<Job>>(
      stream: repo.watchMyJobs(widget.uid),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return const EmptyState(
            icon: Icons.error_outline,
            title: "Couldn't load your jobs",
            message: 'Please check your connection and try again.',
          );
        }
        final jobs = snapshot.data ?? [];
        if (jobs.isEmpty) {
          return const EmptyState(
            icon: Icons.assignment_outlined,
            title: 'No jobs yet',
            message: 'Post a job to start receiving bids.',
          );
        }
        final filtered =
            jobs.where((j) => _filter.matches(j.status)).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _JobFilterBar(
              selected: _filter,
              onSelected: (f) => setState(() => _filter = f),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? EmptyState(
                      icon: Icons.filter_list_off,
                      title: 'No ${_filter.label.toLowerCase()} jobs',
                      message: 'Try a different filter to see your other jobs.',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (context, i) => JobCard(
                        job: filtered[i],
                        onTap: () => context.push('/jobs/${filtered[i].id}'),
                      ),
                    ),
            ),
          ],
        );
      },
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

/// Provider view: the jobs they've won, then their still-pending bids.
class _ProviderJobs extends StatelessWidget {
  const _ProviderJobs({required this.uid});
  final String uid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final jobs = context.read<JobRepository>();
    final bids = context.read<BidRepository>();

    return StreamBuilder<List<Job>>(
      stream: jobs.watchAssignedJobs(uid),
      builder: (context, wonSnapshot) {
        return StreamBuilder<List<Bid>>(
          stream: bids.watchMyBids(uid),
          builder: (context, bidSnapshot) {
            if (wonSnapshot.connectionState == ConnectionState.waiting ||
                bidSnapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (wonSnapshot.hasError || bidSnapshot.hasError) {
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

            if (won.isEmpty && pending.isEmpty) {
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
                if (pending.isNotEmpty) ...[
                  Text('Pending Bids', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 12),
                  for (final bid in pending)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _PendingBidTile(bid: bid),
                    ),
                ],
              ],
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
    return InkWell(
      onTap: () => context.push('/jobs/${bid.jobId}'),
      borderRadius: BorderRadius.circular(12),
      child: AppCard(
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
                label: bid.status.label, color: context.fairbid.warning),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}
