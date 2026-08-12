import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/config/platform_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/user_avatar.dart';
import '../../auth/domain/user_role.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../jobs/presentation/detail/photo_viewer_screen.dart';
import '../data/public_profile_repository.dart';
import '../data/review_repository.dart';
import '../data/user_report_repository.dart';
import '../domain/public_profile.dart';
import '../domain/review.dart';
import 'widgets/review_card.dart';

/// A read-only public view of another user's profile - reachable from a bid
/// card's identity row, a chat thread's header and a review's author name.
///
/// ONE screen with role-conditional sections rather than two screens: a
/// provider and a requestor share the identity header, credibility strip,
/// About and Reviews, so "a profile" reads as one concept everywhere it's
/// opened from. The signed-in user's own uid never reaches this screen - the
/// router redirects `/users/{myUid}` to the canonical `/profile` instead.
class PublicProfileScreen extends StatefulWidget {
  const PublicProfileScreen({super.key, required this.uid});

  final String uid;

  @override
  State<PublicProfileScreen> createState() => _PublicProfileScreenState();
}

class _PublicProfileScreenState extends State<PublicProfileScreen> {
  // Cached so rebuilds don't resubscribe to Firestore.
  late final Stream<PublicProfile?> _profile =
      context.read<PublicProfileRepository>().watchProfile(widget.uid);
  late final Stream<List<Review>> _reviews =
      context.read<ReviewRepository>().watchReviews(widget.uid, limit: 3);

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
            // A failed stream also yields null, so without this the viewer
            // was told the other party had deleted their account whenever the
            // read merely failed.
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
            return _ProfileBody(profile: profile, reviews: _reviews);
          },
        ),
      ),
    );
  }
}

class _ProfileBody extends StatelessWidget {
  const _ProfileBody({required this.profile, required this.reviews});

  final PublicProfile profile;
  final Stream<List<Review>> reviews;

  bool get _isProvider => profile.role == UserRole.provider;

  bool get _hasServices =>
      profile.skills.isNotEmpty ||
      (profile.coverageArea ?? '').isNotEmpty ||
      (profile.hourlyRate ?? '').isNotEmpty;

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
        _isProvider
            ? _CredibilityStrip(profile: profile)
            : _ClientHistoryStrip(profile: profile),
        // No placeholder/coaching copy: an empty About is simply omitted,
        // never "Add a short bio..." (that's second-person, own-profile-only
        // copy) and never a "not provided" row.
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
        _ReviewsCard(
          uid: profile.uid,
          ratingCount: profile.ratingCount,
          averageRating: profile.averageRating,
          reviews: reviews,
        ),
        const SizedBox(height: 24),
        _ReportFooter(uid: profile.uid, name: profile.displayName),
      ],
    );
  }
}

/// Avatar, name, role-specific subtitle and location - identical structure
/// for both roles so a profile always opens the same way.
class _IdentityHeader extends StatelessWidget {
  const _IdentityHeader({required this.profile});
  final PublicProfile profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isProvider = profile.role == UserRole.provider;
    // Providers lead with their coverage area (closer to "where they work");
    // requestors just show their saved location.
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
          isProvider ? _providerTypeLabel(profile.providerType) : 'Client',
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

  String _providerTypeLabel(String? type) => switch (type) {
    'individual' => 'Individual / Freelancer',
    'business' => 'Registered Business',
    _ => 'Provider',
  };
}

/// One metric in the credibility / client-history strip.
class _Stat {
  const _Stat(this.label, this.value);
  final String label;
  final String value;
}

/// Lays out [stats] as [StatCard]s, two per row (the last row holds one when
/// the count is odd), matching the two-column stat grid used elsewhere
/// (e.g. the provider home screen).
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

/// The most-scanned element of a provider's profile: rating, jobs completed,
/// Trust Score (once earned) and a Verified tile (once approved) - exactly
/// what a requestor compares bids by.
class _CredibilityStrip extends StatelessWidget {
  const _CredibilityStrip({required this.profile});
  final PublicProfile profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avg = profile.averageRating;
    final stats = <_Stat>[
      _Stat(
        'Rating',
        avg == null
            ? 'No reviews yet'
            : '★ ${avg.toStringAsFixed(1)} (${profile.ratingCount})',
      ),
      _Stat('Jobs Completed', '${profile.jobsCompleted}'),
      // Never a forged 0/100 - the numeric tile only appears once earned.
      if (profile.scoreVisible)
        _Stat('Trust Score', '${(profile.trustScore / 10).round()}/100'),
      // Never a punitive "Unverified" - the tile only appears once approved.
      if (profile.verificationStatus == 'approved')
        _Stat('Verification', 'Verified'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatsGrid(stats: stats),
        if (!profile.scoreVisible) ...[
          const SizedBox(height: 12),
          const _NewToFairBidBadge(),
          const SizedBox(height: 8),
          Text(
            'New provider, no score yet. Trust Score unlocks after '
            '${PlatformConfig.minJobsForVisibleScore} completed jobs.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// The requestor equivalent of [_CredibilityStrip]: posting history and
/// hire rate instead of trade credentials.
class _ClientHistoryStrip extends StatelessWidget {
  const _ClientHistoryStrip({required this.profile});
  final PublicProfile profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avg = profile.averageRating;
    final stats = <_Stat>[
      if (profile.memberSince != null)
        _Stat('Member Since', _monthYear(profile.memberSince!)),
      _Stat('Jobs Posted', '${profile.jobsPosted}'),
      // Never a forged 0% - omitted until at least one job has been posted.
      if (profile.hireRate != null)
        _Stat('Hire Rate', '${profile.hireRate}%'),
      _Stat('Jobs Completed', '${profile.jobsCompleted}'),
      _Stat(
        'Rating',
        avg == null
            ? 'No reviews yet'
            : '★ ${avg.toStringAsFixed(1)} (${profile.ratingCount})',
      ),
      if (profile.verificationStatus == 'approved')
        _Stat('Verification', 'Verified'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatsGrid(stats: stats),
        if (!profile.scoreVisible) ...[
          const SizedBox(height: 12),
          const _NewToFairBidBadge(),
          const SizedBox(height: 8),
          Text(
            'New client, no score yet. Trust Score unlocks after '
            '${PlatformConfig.minJobsForVisibleScore} completed jobs.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  /// "Aug 2026" - deliberately hand-rolled rather than pulling in `intl`'s
  /// `DateFormat` for one label.
  String _monthYear(DateTime date) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[date.month - 1]} ${date.year}';
  }
}

/// The neutral "still building a track record" badge - never a `0/100`
/// score and never a red "Unverified".
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

/// Provider-only: skills as chips, coverage area and an hourly-rate line.
class _ServicesCard extends StatelessWidget {
  const _ServicesCard({required this.profile});
  final PublicProfile profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rate = (profile.hourlyRate ?? '').isEmpty
        ? null
        : 'From RM ${profile.hourlyRate}/hr';
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
          if (rate != null) ...[
            const SizedBox(height: 8),
            _IconLine(icon: Icons.payments_outlined, text: rate),
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

/// Provider-only: a horizontal photo gallery (full-screen/zoom via the same
/// [PhotoViewerScreen] the job detail Photos section uses), tappable
/// portfolio links and a certificate count line - never the certificate
/// files themselves (see [PublicProfile]'s doc comment).
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
            SizedBox(
              height: 100,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: images.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) => InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => PhotoViewerScreen.show(
                    context,
                    photoUrls: images,
                    initialIndex: i,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      images[i],
                      width: 100,
                      height: 100,
                      // Decode at display size, not the full upload size.
                      cacheWidth: (100 *
                              MediaQuery.devicePixelRatioOf(context))
                          .round(),
                      fit: BoxFit.cover,
                      loadingBuilder: (context, child, loadingProgress) {
                        if (loadingProgress == null) return child;
                        return const SizedBox(
                          width: 100,
                          height: 100,
                          child: Center(
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          ),
                        );
                      },
                      errorBuilder: (context, error, stackTrace) => Container(
                        width: 100,
                        height: 100,
                        color: context.fairbid.borderSubtle,
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
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
              text: '${profile.certificateCount} certificate'
                  '${profile.certificateCount == 1 ? '' : 's'} on file',
            ),
          ],
        ],
      ),
    );
  }
}

/// A tappable portfolio link. There's no in-app browser or `url_launcher`
/// dependency yet, so tapping copies the link instead of opening it - a
/// harmless placeholder until a real "open externally" affordance exists.
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

/// Provider-only: the four Trust Score sub-bars, without the own-profile's
/// second-person coaching hints. Collapsed by default - the headline number
/// is already in the credibility strip above.
class _TrustDetailCard extends StatefulWidget {
  const _TrustDetailCard({required this.profile});
  final PublicProfile profile;

  @override
  State<_TrustDetailCard> createState() => _TrustDetailCardState();
}

class _TrustDetailCardState extends State<_TrustDetailCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trust = widget.profile.trustBreakdown;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            label: _expanded
                ? 'Collapse Trust Score detail'
                : 'Expand Trust Score detail',
            child: InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Trust Score Detail',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
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
            TrustScoreBar(
              label: 'Profile',
              percent: trust?.profileScore ?? 0,
            ),
          ],
        ],
      ),
    );
  }
}

/// Header ("Reviews" + stars + count), the 3 newest reviews inline, and a
/// "See all N reviews" action once there are more than that.
class _ReviewsCard extends StatelessWidget {
  const _ReviewsCard({
    required this.uid,
    required this.ratingCount,
    required this.averageRating,
    required this.reviews,
  });

  final String uid;
  final int ratingCount;
  final double? averageRating;
  final Stream<List<Review>> reviews;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: StreamBuilder<List<Review>>(
        stream: reviews,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const EmptyState(
              icon: Icons.error_outline,
              title: "Couldn't load reviews",
              message: 'Please check your connection and try again.',
            );
          }
          final items = snapshot.data ?? const <Review>[];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('Reviews', style: theme.textTheme.titleLarge),
                  if (averageRating != null) ...[
                    const SizedBox(width: 8),
                    StarRow(rating: averageRating!.round()),
                  ],
                  const SizedBox(width: 4),
                  Text(
                    '($ratingCount)',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (items.isEmpty)
                const EmptyState(
                  icon: Icons.star_border_rounded,
                  title: 'No reviews yet',
                  message: 'Reviews from completed jobs will appear here.',
                )
              else ...[
                for (final (i, review) in items.indexed) ...[
                  if (i > 0) const Divider(height: 24),
                  // Reporting a review is the reviewee's own affordance, not
                  // a public viewer's - they get "Report this user" instead.
                  ReviewCard(review: review, onFlag: null),
                ],
                if (ratingCount > items.length) ...[
                  const SizedBox(height: 12),
                  Center(
                    child: TextButton(
                      onPressed: () => context.push('/users/$uid/reviews'),
                      child: Text('See all $ratingCount reviews'),
                    ),
                  ),
                ],
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Low-emphasis "Report this user" footer - deliberately no Message button;
/// messaging opens through an existing job/bid/conversation, not from a cold
/// profile view.
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

  /// Files the report for real (see [UserReportRepository]). The copy below
  /// deliberately promises only what actually happens, that the report was
  /// received and recorded: no admin triage UI reads the `reports`
  /// collection yet, so promising a review would be an assurance the system
  /// can't currently keep. A failed write says so plainly rather than
  /// showing a success message over a dropped report.
  Future<void> _report(BuildContext context) async {
    final reports = context.read<UserReportRepository>();
    final reporterId = context.read<AuthController>().user?.uid;
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => _ReportUserDialog(name: name),
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

/// Reason dialog for reporting a user. Returns the reason on confirm
/// (required) or null on cancel - mirrors profile_screen.dart's
/// `_FlagReviewDialog`.
class _ReportUserDialog extends StatefulWidget {
  const _ReportUserDialog({required this.name});
  final String name;

  @override
  State<_ReportUserDialog> createState() => _ReportUserDialogState();
}

class _ReportUserDialogState extends State<_ReportUserDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Report ${widget.name}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tell the admins what happened.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            maxLines: 3,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'e.g. This user asked to pay outside the app.',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _controller.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Report'),
        ),
      ],
    );
  }
}
