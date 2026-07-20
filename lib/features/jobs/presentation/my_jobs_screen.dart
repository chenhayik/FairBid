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

class _RequestorJobs extends StatelessWidget {
  const _RequestorJobs({required this.uid});
  final String uid;

  @override
  Widget build(BuildContext context) {
    final repo = context.read<JobRepository>();
    return StreamBuilder<List<Job>>(
      stream: repo.watchMyJobs(uid),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final jobs = snapshot.data ?? [];
        if (jobs.isEmpty) {
          return const EmptyState(
            icon: Icons.assignment_outlined,
            title: 'No jobs yet',
            message: 'Post a job to start receiving bids.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(24),
          itemCount: jobs.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, i) => JobCard(
            job: jobs[i],
            onTap: () => context.push('/jobs/${jobs[i].id}'),
          ),
        );
      },
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
