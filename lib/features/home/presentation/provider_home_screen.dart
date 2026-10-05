import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../../core/location/geo.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/util/money.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/keyed_stream_builder.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../auth/presentation/email_verification_banner.dart';
import '../../jobs/data/bid_repository.dart';
import '../../jobs/data/bundle_bid_repository.dart';
import '../../jobs/data/job_repository.dart';
import '../../jobs/data/milestone_repository.dart';
import '../../jobs/domain/bid.dart';
import '../../jobs/domain/bundle_bid.dart';
import '../../jobs/domain/job.dart';
import '../../jobs/domain/milestone.dart';
import '../../jobs/presentation/widgets/job_card.dart';
import 'home_app_bar.dart';

/// Provider Home: verification status, key stat cards, and the "jobs near you"
/// section.
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
            const EmailVerificationBanner(),
            _VerificationBadge(status: status),
            const SizedBox(height: 16),
            if (status == 'rejected') ...[
              InfoBanner(
                icon: Icons.warning_amber_rounded,
                color: context.fairbid.warningText,
                leftAccent: true,
                title: 'Action required',
                body:
                    'Your verification was rejected. Please re-submit your '
                    'documents to unlock bidding.',
              ),
              const SizedBox(height: 12),
              PrimaryButton(
                label: 'Re-submit documents',
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
            // IntrinsicHeight + stretch keeps both cards in a row equally tall.
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
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
            ),
            const SizedBox(height: 12),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _PendingBidsStat(uid: user?.uid)),
                  const SizedBox(width: 12),
                  Expanded(child: _TotalEarningsStat(uid: user?.uid)),
                ],
              ),
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
      return const StatCard(label: 'Active jobs', value: '0');
    }
    return KeyedStreamBuilder<List<Job>>(
      cacheKey: uid,
      create: () => context.read<JobRepository>().watchAssignedJobs(uid!),
      builder: (context, snapshot) {
        if (snapshot.hasError ||
            snapshot.connectionState == ConnectionState.waiting) {
          return const StatCard(label: 'Active jobs', value: '-');
        }
        final active = (snapshot.data ?? [])
            .where((j) => j.status == JobStatus.inProgress)
            .length;
        return StatCard(label: 'Active jobs', value: '$active');
      },
    );
  }
}

/// Live count of the provider's still-pending bids - ordinary per-job bids
/// plus package bids on a bundle.
class _PendingBidsStat extends StatelessWidget {
  const _PendingBidsStat({required this.uid});
  final String? uid;

  @override
  Widget build(BuildContext context) {
    if (uid == null) {
      return const StatCard(label: 'Pending bids', value: '0');
    }
    return KeyedStreamBuilder<List<Bid>>(
      cacheKey: uid,
      create: () => context.read<BidRepository>().watchMyBids(uid!),
      builder: (context, bidSnapshot) {
        return KeyedStreamBuilder<List<BundleBid>>(
          cacheKey: uid,
          create: () =>
              context.read<BundleBidRepository>().watchMyBundleBids(uid!),
          builder: (context, bundleBidSnapshot) {
            if (bidSnapshot.hasError ||
                bundleBidSnapshot.hasError ||
                bidSnapshot.connectionState == ConnectionState.waiting ||
                bundleBidSnapshot.connectionState == ConnectionState.waiting) {
              return const StatCard(label: 'Pending bids', value: '-');
            }
            final pending = (bidSnapshot.data ?? [])
                .where((b) => b.status == BidStatus.pending)
                .length;
            final pendingBundles = (bundleBidSnapshot.data ?? [])
                .where((b) => b.status == BundleBidStatus.pending)
                .length;
            return StatCard(
              label: 'Pending bids',
              value: '${pending + pendingBundles}',
            );
          },
        );
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
      return const StatCard(label: 'Total earnings', value: '-');
    }
    return KeyedStreamBuilder<List<Milestone>>(
      cacheKey: uid,
      create: () =>
          context.read<MilestoneRepository>().watchProviderMilestones(uid!),
      builder: (context, snapshot) {
        if (snapshot.hasError ||
            snapshot.connectionState == ConnectionState.waiting) {
          return const StatCard(label: 'Total earnings', value: '-');
        }
        final earnedSen = (snapshot.data ?? [])
            .where((m) =>
                m.status == MilestoneStatus.released ||
                m.status == MilestoneStatus.resolved)
            .fold<int>(0, (sum, m) => sum + m.amountSen);
        return StatCard(label: 'Total earnings', value: formatRm(earnedSen));
      },
    );
  }
}

/// The nearest few open jobs for the provider home - or, with no location
/// saved yet, the newest few plus a prompt to set one.
class _NearbyJobs extends StatelessWidget {
  const _NearbyJobs();

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthController>().user;
    final repo = context.read<JobRepository>();
    final base = user != null && user.hasBaseLocation
        ? LatLng(user.baseLat!, user.baseLng!)
        : null;

    return KeyedStreamBuilder<List<Job>>(
      // Only the three nearest are shown, but "nearest" is ranked in Dart, so
      // the window has to be wide enough that a close-but-older job is not
      // cut off by recency first. A wider bound than the feed's is the
      // pragmatic middle ground; a proper fix needs geo-queries (geohash),
      // which is a much larger change.
      create: () => repo.watchOpenJobs(limit: 100),
      builder: (context, snapshot) {
        // Loading and error both used to fall through to "No jobs yet", so a
        // provider was told there was no work near them while the query was
        // still running, or whenever it failed.
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const AppCard(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }
        if (snapshot.hasError) {
          return const AppCard(
            child: EmptyState(
              icon: Icons.error_outline,
              title: "Couldn't load nearby jobs",
              message: 'Please check your connection and try again.',
            ),
          );
        }
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
        // Newest first (the query's order) until a location makes distance
        // meaningful.
        final ranked = [
          for (final job in jobs)
            (
              job,
              base == null
                  ? null
                  : distanceKm(base, LatLng(job.location.lat, job.location.lng)),
            ),
        ];
        if (base != null) ranked.sort((a, b) => a.$2!.compareTo(b.$2!));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (base == null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => context.push('/jobs'),
                  icon: const Icon(Icons.my_location, size: 18),
                  label: const Text('Set your location to sort by distance'),
                ),
              ),
            for (final (job, km) in ranked.take(3))
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: JobCard(
                  job: job,
                  distanceLabel: km == null ? null : formatDistance(km),
                  onTap: () => context.push('/jobs/${job.id}'),
                  saved: user?.isSaved(job.id) ?? false,
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
          'Identity verified',
          Icons.verified,
          context.fairbid.verified
        ),
      'pending' => (
          'Verification pending',
          Icons.hourglass_top_rounded,
          context.fairbid.warningText
        ),
      'rejected' => (
          'Verification rejected',
          Icons.error_outline,
          context.fairbid.danger
        ),
      _ => ('Unverified', Icons.info_outline, context.fairbid.warningText),
    };
    return Align(
      alignment: Alignment.centerLeft,
      child: PillBadge(label: label, icon: icon, color: color),
    );
  }
}
