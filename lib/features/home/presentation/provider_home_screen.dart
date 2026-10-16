import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../../core/location/geo.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/util/money.dart';
import '../../../core/util/visit_time.dart';
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

/// What:   Provider Home: verification status, stat cards, upcoming visits and nearby jobs.
/// Input:  [AuthController] user; job, bid and milestone repositories.
/// Output: Dashboard list.
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
            // IntrinsicHeight + stretch keeps a row's cards equally tall.
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: StatCard(
                      label: 'Trust Score',
                      // Hidden until earned.
                      value: scoreVisible ? '$trustPercent/100' : 'New',
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
            _UpcomingVisits(uid: user?.uid),
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

/// What:   Count of the provider's in-progress jobs.
/// Input:  [uid]; JobRepository.watchAssignedJobs() (job_repository.dart).
/// Output: StatCard showing the count, "-" while loading or on error, 0 when signed out.
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

/// What:   Confirmed visits that started less than 2h ago or are upcoming.
/// Input:  [uid]; JobRepository.watchAssignedJobs() (job_repository.dart).
/// Output: A card per in-progress job with an appointment, by start time; a clash chip when another visit is within 2h. Nothing when empty.
class _UpcomingVisits extends StatelessWidget {
  const _UpcomingVisits({required this.uid});
  final String? uid;

  static const _window = Duration(hours: 2);

  @override
  Widget build(BuildContext context) {
    if (uid == null) return const SizedBox.shrink();
    return KeyedStreamBuilder<List<Job>>(
      cacheKey: uid,
      create: () => context.read<JobRepository>().watchAssignedJobs(uid!),
      builder: (context, snapshot) {
        final cutoff = DateTime.now().subtract(_window);
        final visits = [
          for (final j in snapshot.data ?? <Job>[])
            if (j.status == JobStatus.inProgress &&
                j.appointment != null &&
                j.appointment!.startAt.isAfter(cutoff))
              j,
        ]..sort((a, b) =>
            a.appointment!.startAt.compareTo(b.appointment!.startAt));
        if (visits.isEmpty) return const SizedBox.shrink();
        bool clashes(Job j) => visits.any((o) =>
            o != j &&
            o.appointment!.startAt
                    .difference(j.appointment!.startAt)
                    .abs() <
                _window);
        return Padding(
          padding: const EdgeInsets.only(top: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Upcoming visits',
                  style: Theme.of(context).textTheme.titleLarge),
              for (final job in visits)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: AppCard(
                    onTap: () => context.push('/jobs/${job.id}'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(formatVisitTime(job.appointment!.startAt),
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 4),
                        Text(job.title),
                        Text(job.location.town ?? job.location.address,
                            style: Theme.of(context).textTheme.bodyMedium),
                        if (clashes(job)) ...[
                          const SizedBox(height: 8),
                          PillBadge(
                            label: 'Close to another visit',
                            icon: Icons.warning_amber_rounded,
                            color: context.fairbid.warningText,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// What:   Count of the provider's pending per-job and bundle bids.
/// Input:  [uid]; BidRepository.watchMyBids() and BundleBidRepository.watchMyBundleBids().
/// Output: StatCard with both pending counts added, "-" while loading or on error, 0 when signed out.
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

/// What:   Total of the provider's released milestone payments across every job.
/// Input:  [uid]; MilestoneRepository.watchProviderMilestones() (milestone_repository.dart).
/// Output: StatCard with the sum of released and resolved milestone amounts in RM, "-" while loading or on error.
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

/// What:   The three nearest open jobs, or the newest three plus a prompt when no location is saved.
/// Input:  JobRepository.watchOpenJobs(limit: 100); the provider's base location from AuthController.user.
/// Output: Up to three JobCards with distance labels, or a "Set your location" button when there is no base location.
/// How:    Distance is ranked in Dart over a wide window so a close-but-older job is not cut off.
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
      // Distance is ranked in Dart, so fetch a wide window or a close-but-older job is cut off.
      create: () => repo.watchOpenJobs(limit: 100),
      builder: (context, snapshot) {
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
        // Newest first (the query's order) until a location exists.
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

/// What:   Pill showing the provider's verification status.
/// Input:  [status] from AppUser.verificationStatus ('approved', 'pending', 'rejected' or other).
/// Output: Identity verified, Verification pending, Verification rejected or Unverified.
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
