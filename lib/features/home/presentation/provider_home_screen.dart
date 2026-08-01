import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../../core/location/geo.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/util/money.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../jobs/data/bid_repository.dart';
import '../../jobs/data/job_repository.dart';
import '../../jobs/data/milestone_repository.dart';
import '../../jobs/domain/bid.dart';
import '../../jobs/domain/job.dart';
import '../../jobs/domain/milestone.dart';
import '../../jobs/presentation/widgets/job_card.dart';
import 'home_app_bar.dart';

/// Provider Home: verification status, key stat cards, and the "jobs near you"
/// section (empty until the Jobs feature is built).
class ProviderHomeScreen extends StatelessWidget {
  const ProviderHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = context.watch<AuthController>().user;
    final status = user?.verificationStatus ?? 'none';
    final scoreVisible = user?.scoreVisible ?? false;
    final trustPercent = ((user?.trustScore ?? 0) / 10).round();

    return Scaffold(
      appBar: const HomeAppBar(),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            _VerificationBadge(status: status),
            const SizedBox(height: 16),
            if (status == 'rejected') ...[
              InfoBanner(
                icon: Icons.warning_amber_rounded,
                color: context.fairbid.warningText,
                leftAccent: true,
                title: 'Action Required',
                body:
                    'Your verification was rejected. Please re-submit your '
                    'documents to unlock bidding.',
              ),
              const SizedBox(height: 12),
              PrimaryButton(
                label: 'Re-submit Documents',
                onPressed: () => context.push('/onboarding'),
              ),
            ],
            if (status == 'pending')
              const InfoBanner(
                icon: Icons.hourglass_top_rounded,
                title: 'Verification in progress',
                body:
                    'You can browse jobs now. Bidding unlocks once an admin '
                    'approves your documents.',
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: StatCard(
                    label: 'Trust Score',
                    // Hidden until earned (verified + enough completed jobs).
                    value: scoreVisible ? '$trustPercent%' : 'New',
                    icon: Icons.shield_outlined,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ActiveJobsStat(uid: user?.uid),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _PendingBidsStat(uid: user?.uid)),
                const SizedBox(width: 12),
                Expanded(child: _TotalEarningsStat(uid: user?.uid)),
              ],
            ),
            const SizedBox(height: 32),
            Row(
              children: [
                Expanded(
                  child:
                      Text('Jobs near you', style: theme.textTheme.titleLarge),
                ),
                TextButton(
                  onPressed: () => context.push('/jobs'),
                  child: const Text('View all'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const _NearbyJobs(),
          ],
        ),
      ),
    );
  }
}

/// Live count of the provider's jobs currently in progress.
class _ActiveJobsStat extends StatelessWidget {
  const _ActiveJobsStat({required this.uid});
  final String? uid;

  @override
  Widget build(BuildContext context) {
    if (uid == null) {
      return const StatCard(label: 'Active Jobs', value: '0');
    }
    return StreamBuilder<List<Job>>(
      stream: context.read<JobRepository>().watchAssignedJobs(uid!),
      builder: (context, snapshot) {
        if (snapshot.hasError ||
            snapshot.connectionState == ConnectionState.waiting) {
          return const StatCard(label: 'Active Jobs', value: '-');
        }
        final active = (snapshot.data ?? [])
            .where((j) => j.status == JobStatus.inProgress)
            .length;
        return StatCard(label: 'Active Jobs', value: '$active');
      },
    );
  }
}

/// Live count of the provider's still-pending bids.
class _PendingBidsStat extends StatelessWidget {
  const _PendingBidsStat({required this.uid});
  final String? uid;

  @override
  Widget build(BuildContext context) {
    if (uid == null) {
      return const StatCard(label: 'Pending Bids', value: '0');
    }
    return StreamBuilder<List<Bid>>(
      stream: context.read<BidRepository>().watchMyBids(uid!),
      builder: (context, snapshot) {
        if (snapshot.hasError ||
            snapshot.connectionState == ConnectionState.waiting) {
          return const StatCard(label: 'Pending Bids', value: '-');
        }
        final pending = (snapshot.data ?? [])
            .where((b) => b.status == BidStatus.pending)
            .length;
        return StatCard(label: 'Pending Bids', value: '$pending');
      },
    );
  }
}

/// Live total of the provider's released milestone payments across every job
/// (relabelled from "Earnings (MTD)": month-to-date filtering isn't tracked).
class _TotalEarningsStat extends StatelessWidget {
  const _TotalEarningsStat({required this.uid});
  final String? uid;

  @override
  Widget build(BuildContext context) {
    if (uid == null) {
      return const StatCard(label: 'Total Earnings', value: '-');
    }
    return StreamBuilder<List<Milestone>>(
      stream:
          context.read<MilestoneRepository>().watchProviderMilestones(uid!),
      builder: (context, snapshot) {
        if (snapshot.hasError ||
            snapshot.connectionState == ConnectionState.waiting) {
          return const StatCard(label: 'Total Earnings', value: '-');
        }
        final earnedSen = (snapshot.data ?? [])
            .where((m) =>
                m.status == MilestoneStatus.released ||
                m.status == MilestoneStatus.resolved)
            .fold<int>(0, (sum, m) => sum + m.amountSen);
        return StatCard(label: 'Total Earnings', value: formatRm(earnedSen));
      },
    );
  }
}

/// The nearest few open jobs for the provider home. Prompts to set a base
/// location when none is saved yet.
class _NearbyJobs extends StatelessWidget {
  const _NearbyJobs();

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthController>().user;
    final repo = context.read<JobRepository>();

    if (user == null || !user.hasBaseLocation) {
      return AppCard(
        child: EmptyState(
          icon: Icons.my_location,
          title: 'See jobs near you',
          message: 'Browse jobs and set your location to sort by distance.',
        ),
      );
    }

    final base = LatLng(user.baseLat!, user.baseLng!);
    return StreamBuilder<List<Job>>(
      stream: repo.watchOpenJobs(),
      builder: (context, snapshot) {
        final jobs = snapshot.data ?? [];
        if (jobs.isEmpty) {
          return const AppCard(
            child: EmptyState(
              icon: Icons.search_off_rounded,
              title: 'No jobs yet',
              message: 'Nearby jobs will appear here as requestors post.',
            ),
          );
        }
        final ranked = [
          for (final job in jobs)
            (job, distanceKm(base, LatLng(job.location.lat, job.location.lng)))
        ]..sort((a, b) => a.$2.compareTo(b.$2));
        return Column(
          children: [
            for (final (job, km) in ranked.take(3))
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: JobCard(
                  job: job,
                  distanceLabel: formatDistance(km),
                  onTap: () => context.push('/jobs/${job.id}'),
                  saved: user.isSaved(job.id),
                  onToggleSave: () =>
                      context.read<AuthController>().toggleSaved(job.id),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _VerificationBadge extends StatelessWidget {
  const _VerificationBadge({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, icon, color) = switch (status) {
      'approved' => (
          'Identity Verified',
          Icons.verified,
          context.fairbid.verified
        ),
      'pending' => (
          'Verification Pending',
          Icons.hourglass_top_rounded,
          context.fairbid.warning
        ),
      'rejected' => (
          'Verification Rejected',
          Icons.error_outline,
          context.fairbid.danger
        ),
      _ => ('Unverified', Icons.info_outline, context.fairbid.warning),
    };
    return Align(
      alignment: Alignment.centerLeft,
      child: PillBadge(label: label, icon: icon, color: color),
    );
  }
}
