import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/config/platform_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/util/plural.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/form_widgets.dart';
import '../../../core/widgets/user_avatar.dart';
import '../../auth/domain/user_role.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../jobs/presentation/detail/photo_strip.dart';
import '../../onboarding/domain/onboarding_data.dart';
import '../data/public_profile_repository.dart';
import '../data/user_report_repository.dart';
import '../domain/public_profile.dart';
import 'widgets/review_card.dart';
import 'widgets/review_list.dart';

/// What:   Read-only public view of another user's profile (from a bid card, chat header or review author).
/// Input:  [uid]; PublicProfileRepository.watchProfile() (public_profile_repository.dart).
/// Output: One screen with role-conditional sections. The router redirects `/users/{myUid}` to `/profile`.
class PublicProfileScreen extends StatefulWidget {
  const PublicProfileScreen({super.key, required this.uid});

  final String uid;

  @override
  State<PublicProfileScreen> createState() => _PublicProfileScreenState();
}

class _PublicProfileScreenState extends State<PublicProfileScreen> {
  // Created once so rebuilds don't resubscribe.
  late final Stream<PublicProfile?> _profile =
      context.read<PublicProfileRepository>().watchProfile(widget.uid);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: SafeArea(
        child: StreamBuilder<PublicProfile?>(
          stream: _profile,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            // A failed stream also yields null; don't call that "deleted".
            if (snapshot.hasError) {
              return const EmptyState(
                icon: Icons.cloud_off,
                title: "Couldn't load this profile",
                message: 'Check your connection, then go back and open it '
                    'again.',
              );
            }
            final profile = snapshot.data;
            if (profile == null) {
              return const EmptyState(
                icon: Icons.person_off_outlined,
                title: 'Profile not found',
                message: 'This account may have been deleted.',
              );
            }
            return _ProfileBody(profile: profile);
          },
        ),
      ),
    );
  }
}

/// What:   The profile sections for the viewed role.
/// Input:  [profile] from PublicProfileRepository.watchProfile().
/// Output: Header, stats, About, provider sections, reviews and the report footer.
class _ProfileBody extends StatelessWidget {
  const _ProfileBody({required this.profile});

  final PublicProfile profile;

  /// Rating, jobs, Trust Score (once earned) and Verified (once approved): what a requestor compares bids by.
  Widget _credibilityStrip() {
    final avg = profile.averageRating;
    return _StatsStrip(
      profile: profile,
      newLabel: 'provider',
      stats: [
        _Stat(
          'Rating',
          avg == null
              ? 'No reviews yet'
              : '★ ${avg.toStringAsFixed(1)} (${profile.ratingCount})',
        ),
        _Stat('Jobs Completed', '${profile.jobsCompleted}'),
        if (profile.scoreVisible)
          _Stat('Trust Score', '${(profile.trustScore / 10).round()}/100'),
        if (profile.verificationStatus == 'approved')
          _Stat('Verification', 'Verified'),
      ],
    );
  }

  /// Posting history and hire rate instead of trade credentials.
  Widget _clientHistoryStrip() {
    final avg = profile.averageRating;
    return _StatsStrip(
      profile: profile,
      newLabel: 'client',
      stats: [
        if (profile.memberSince != null)
          _Stat('Member Since', DateFormat('MMM y').format(profile.memberSince!)),
        _Stat('Jobs Posted', '${profile.jobsPosted}'),
        // Omitted until a job exists, never a forged 0%.
        if (profile.hireRate != null) _Stat('Hire Rate', '${profile.hireRate}%'),
        _Stat('Jobs Completed', '${profile.jobsCompleted}'),
        _Stat(
          'Rating',
          avg == null
              ? 'No reviews yet'
              : '★ ${avg.toStringAsFixed(1)} (${profile.ratingCount})',
        ),
        if (profile.verificationStatus == 'approved')
          _Stat('Verification', 'Verified'),
      ],
    );
  }

  bool get _isProvider => profile.role == UserRole.provider;

  bool get _hasServices =>
      profile.skills.isNotEmpty ||
      (profile.coverageArea ?? '').isNotEmpty;

  bool get _hasPortfolio =>
      profile.portfolioImageUrls.isNotEmpty ||
      profile.portfolioLinks.isNotEmpty ||
      profile.certificateCount > 0;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _IdentityHeader(profile: profile),
        const SizedBox(height: 24),
        _isProvider ? _credibilityStrip() : _clientHistoryStrip(),
        // An empty About is omitted, never a coaching placeholder.
        if ((profile.bio ?? '').isNotEmpty) ...[
          const SizedBox(height: 16),
          _AboutCard(bio: profile.bio!),
        ],
        if (_isProvider) ...[
          if (_hasServices) ...[
            const SizedBox(height: 16),
            _ServicesCard(profile: profile),
          ],
          if (_hasPortfolio) ...[
            const SizedBox(height: 16),
            _PortfolioCard(profile: profile),
          ],
          const SizedBox(height: 16),
          _TrustDetailCard(profile: profile),
        ],
        const SizedBox(height: 16),
        ReviewList(
          uid: profile.uid,
          seeAllCount: profile.ratingCount,
          header: Row(
            children: [
              Text('Reviews', style: Theme.of(context).textTheme.titleLarge),
              if (profile.averageRating != null) ...[
                const SizedBox(width: 8),
                StarRow(rating: profile.averageRating!.round()),
              ],
              const SizedBox(width: 4),
              Text(
                '(${profile.ratingCount})',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _ReportFooter(uid: profile.uid, name: profile.displayName),
      ],
    );
  }
}

/// Avatar, name, role subtitle, category and location, in the same layout for both roles.
class _IdentityHeader extends StatelessWidget {
  const _IdentityHeader({required this.profile});
  final PublicProfile profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isProvider = profile.role == UserRole.provider;
    // Providers lead with their coverage area, requestors with their saved location.
    final area = isProvider
        ? ((profile.coverageArea ?? '').isNotEmpty
              ? profile.coverageArea
              : profile.location)
        : profile.location;

    return Column(
      children: [
        UserAvatar(photoUrl: profile.photoUrl, radius: 40, iconSize: 40),
        const SizedBox(height: 12),
        Text(
          profile.displayName,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineMedium,
        ),
        const SizedBox(height: 4),
        Text(
          isProvider
              ? ProviderType.fromStorage(profile.providerType)?.label ??
                  'Provider'
              : 'Client',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (isProvider && (profile.category ?? '').isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            profile.category!,
            style: theme.textTheme.titleMedium?.copyWith(
              color: context.fairbid.verified,
            ),
          ),
        ],
        if ((area ?? '').isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.location_on_outlined,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  area!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

}

/// One stat tile's label and value.
class _Stat {
  const _Stat(this.label, this.value);
  final String label;
  final String value;
}

/// [stats] as [StatCard]s, two per row.
class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.stats});
  final List<_Stat> stats;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < stats.length; i += 2) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 12));
      final pair = stats.skip(i).take(2).toList();
      rows.add(
        Row(
          children: [
            for (final (j, stat) in pair.indexed) ...[
              if (j > 0) const SizedBox(width: 12),
              Expanded(
                child: StatCard(label: stat.label, value: stat.value),
              ),
            ],
          ],
        ),
      );
    }
    return Column(children: rows);
  }
}

/// What:   Stat tiles plus the "New to FairBid" notice until the Trust Score is earned.
/// Input:  [profile]; [stats] for the viewed role and [newLabel] ("provider" / "client").
/// Output: Stats grid; the notice never shows a 0/100 score or a red "Unverified".
class _StatsStrip extends StatelessWidget {
  const _StatsStrip({
    required this.profile,
    required this.stats,
    required this.newLabel,
  });
  final PublicProfile profile;
  final List<_Stat> stats;
  final String newLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatsGrid(stats: stats),
        if (!profile.scoreVisible) ...[
          const SizedBox(height: 12),
          const _NewToFairBidBadge(),
          const SizedBox(height: 8),
          Text(
            'New $newLabel, no score yet. Trust Score unlocks after '
            '${PlatformConfig.minJobsForVisibleScore} completed jobs.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _NewToFairBidBadge extends StatelessWidget {
  const _NewToFairBidBadge();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        PillBadge(
          label: 'New to FairBid',
          icon: Icons.auto_awesome,
          color: context.fairbid.verified,
        ),
      ],
    );
  }
}

class _AboutCard extends StatelessWidget {
  const _AboutCard({required this.bio});
  final String bio;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('About', style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(bio, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// Provider skills as chips and the coverage area.
class _ServicesCard extends StatelessWidget {
  const _ServicesCard({required this.profile});
  final PublicProfile profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Services', style: theme.textTheme.titleLarge),
          if (profile.skills.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final skill in profile.skills)
                  PillBadge(label: skill, color: context.fairbid.verified),
              ],
            ),
          ],
          if ((profile.coverageArea ?? '').isNotEmpty) ...[
            const SizedBox(height: 12),
            _IconLine(
              icon: Icons.map_outlined,
              text: profile.coverageArea!,
            ),
          ],
        ],
      ),
    );
  }
}

class _IconLine extends StatelessWidget {
  const _IconLine({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: theme.textTheme.bodyMedium),
        ),
      ],
    );
  }
}

/// Provider portfolio: photo strip, copyable links and a certificate count (never the files).
class _PortfolioCard extends StatelessWidget {
  const _PortfolioCard({required this.profile});
  final PublicProfile profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final images = profile.portfolioImageUrls;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Portfolio', style: theme.textTheme.titleLarge),
          if (images.isNotEmpty) ...[
            const SizedBox(height: 12),
            PhotoStrip(photoUrls: images),
          ],
          if (profile.portfolioLinks.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final link in profile.portfolioLinks)
              _PortfolioLinkRow(link: link),
          ],
          if (profile.certificateCount > 0) ...[
            const SizedBox(height: 12),
            _IconLine(
              icon: Icons.workspace_premium_outlined,
              text: '${plural(profile.certificateCount, 'certificate')} on file',
            ),
          ],
        ],
      ),
    );
  }
}

/// A portfolio link; tapping copies it (opening externally isn't wired yet).
class _PortfolioLinkRow extends StatelessWidget {
  const _PortfolioLinkRow({required this.link});
  final String link;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => _copy(context),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(Icons.link, size: 16, color: context.fairbid.verified),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                link,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: context.fairbid.verified,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: link));
    messenger.showSnackBar(
      const SnackBar(content: Text('Link copied to clipboard.')),
    );
  }
}

/// Provider Trust Score sub-bars without own-profile coaching hints; collapsed by default.
class _TrustDetailCard extends StatelessWidget {
  const _TrustDetailCard({required this.profile});
  final PublicProfile profile;

  @override
  Widget build(BuildContext context) {
    final trust = profile.trustBreakdown;
    return AppCard(
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(
          'Trust Score Detail',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        children: [
          const Divider(height: 32),
          TrustScoreBar(label: 'Reviews', percent: trust?.reviewScore ?? 0),
          TrustScoreBar(
            label: 'Track Record',
            percent: trust?.trackRecordScore ?? 0,
          ),
          TrustScoreBar(
            label: 'Verification',
            percent: trust?.verificationScore ?? 0,
          ),
          TrustScoreBar(label: 'Profile', percent: trust?.profileScore ?? 0),
        ],
      ),
    );
  }
}

/// Low-emphasis "Report this user" footer; no Message button, since chat opens from a job.
class _ReportFooter extends StatelessWidget {
  const _ReportFooter({required this.uid, required this.name});
  final String uid;
  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: TextButton.icon(
        onPressed: () => _report(context),
        icon: Icon(
          Icons.flag_outlined,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        label: Text(
          'Report this user',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }

  /// Files the report via [UserReportRepository]. The copy promises only that it was recorded,
  /// since no admin screen reads `reports` yet.
  Future<void> _report(BuildContext context) async {
    final reports = context.read<UserReportRepository>();
    final reporterId = context.read<AuthController>().user?.uid;
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => ReasonDialog(
        title: 'Report $name?',
        message: 'Tell the admins what happened.',
        hint: 'e.g. This user asked to pay outside the app.',
        confirmLabel: 'Report',
      ),
    );
    if (reason == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (reporterId == null) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Please sign in again to report someone.')));
      return;
    }
    try {
      await reports.reportUser(
        reporterId: reporterId,
        reportedUid: uid,
        reason: reason,
      );
      messenger.showSnackBar(const SnackBar(
          content: Text('Report received. Our team keeps a record of it.')));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
          content: Text(
              "Couldn't send your report. Please check your connection and "
              'try again.')));
    }
  }
}
