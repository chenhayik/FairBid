import 'dart:math' show min;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../../core/config/platform_config.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/money.dart';
import '../../../../core/util/time_ago.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../auth/domain/app_user.dart';
import '../../../auth/presentation/auth_controller.dart';
import '../../../messages/data/chat_repository.dart';
import '../../../profile/presentation/leave_review_sheet.dart';
import '../../data/bid_repository.dart';
import '../../data/job_repository.dart';
import '../../domain/bid.dart';
import '../../domain/job.dart';
import '../../domain/job_event.dart';
import '../bid/submit_bid_sheet.dart';
import '../widgets/bid_card.dart';
import 'job_address_card.dart';
import 'milestone_section.dart';

/// Full job detail. The requestor compares and accepts bids; a verified
/// provider submits (or withdraws) their bid.
class JobDetailScreen extends StatefulWidget {
  const JobDetailScreen({super.key, required this.jobId});

  final String jobId;

  @override
  State<JobDetailScreen> createState() => _JobDetailScreenState();
}

class _JobDetailScreenState extends State<JobDetailScreen> {
  // Cached so rebuilds don't resubscribe to Firestore.
  late final Stream<Job?> _job =
      context.read<JobRepository>().watchJob(widget.jobId);

  @override
  Widget build(BuildContext context) {
    final myUid = context.read<AuthController>().user?.uid;

    return Scaffold(
      appBar: AppBar(title: const Text('Job Details')),
      body: SafeArea(
        child: StreamBuilder<Job?>(
          stream: _job,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final job = snapshot.data;
            if (job == null) {
              return const EmptyState(
                icon: Icons.search_off_rounded,
                title: 'Job not found',
                message: 'It may have been removed by the requestor.',
              );
            }
            final isOwner = job.requestorId == myUid;
            return _JobBody(job: job, isOwner: isOwner);
          },
        ),
      ),
    );
  }
}

class _JobBody extends StatelessWidget {
  const _JobBody({required this.job, required this.isOwner});
  final Job job;
  final bool isOwner;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child:
                  PillBadge(label: job.category, color: context.fairbid.verified),
            ),
            PillBadge(
                label: job.status.label,
                color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
        const SizedBox(height: 16),
        Text(job.title, style: theme.textTheme.headlineMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(Icons.schedule,
                size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text('Posted ${timeAgo(job.createdAt)}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: 16),
        if (job.budget?.label != null)
          _InfoRow(
              icon: Icons.payments_outlined,
              label: 'Budget',
              value: job.budget!.label!),
        _InfoRow(
            icon: Icons.location_on_outlined,
            label: 'Location',
            value: job.location.address),
        if (job.deadline != null)
          _InfoRow(
              icon: Icons.timer_outlined,
              label: 'Bidding',
              value: deadlineLabel(job.deadline)),
        const SizedBox(height: 16),
        Text('Description', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(job.description, style: theme.textTheme.bodyLarge),
        if (job.photoUrls.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Photos', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          SizedBox(
            height: 120,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: job.photoUrls.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) => ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  job.photoUrls[i],
                  width: 120,
                  height: 120,
                  fit: BoxFit.cover,
                  loadingBuilder: (context, child, loadingProgress) {
                    if (loadingProgress == null) return child;
                    return const SizedBox(
                      width: 120,
                      height: 120,
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  },
                  errorBuilder: (context, error, stackTrace) => Container(
                    width: 120,
                    height: 120,
                    color: context.fairbid.borderSubtle,
                    child: Icon(Icons.broken_image_outlined,
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
        if (isOwner)
          _RequestorSection(job: job)
        else
          _ProviderSection(job: job),
        // An open job has only its lone "posted" event — not worth a card.
        if (job.status != JobStatus.open) ...[
          const SizedBox(height: 16),
          _JobTimeline(jobId: job.id),
        ],
      ],
    );
  }
}

/// Icon shown against a timeline entry, keyed by [JobEvent.type].
IconData _timelineIcon(String type) => switch (type) {
      'posted' => Icons.post_add,
      'assigned' => Icons.handshake_outlined,
      'funded' => Icons.lock_outline,
      'submitted' => Icons.inventory_2_outlined,
      'released' => Icons.payments_outlined,
      'disputed' => Icons.gavel_rounded,
      'refunded' => Icons.undo,
      'completed' => Icons.check_circle_outline,
      'cancelled' => Icons.cancel_outlined,
      _ => Icons.circle,
    };

/// Colour shown against a timeline entry, keyed by [JobEvent.type], matching
/// the semantic colours used elsewhere (danger/warning/success/verified).
Color _timelineColor(BuildContext context, String type) => switch (type) {
      'cancelled' || 'disputed' => context.fairbid.danger,
      'refunded' => context.fairbid.warning,
      'released' || 'completed' => context.fairbid.success,
      _ => context.fairbid.verified,
    };

/// The job's server-written activity log (plan §3.x): a simple vertical list
/// of `posted`/`assigned`/milestone/`completed`/`cancelled` events, oldest
/// first. Shows nothing while waiting or when there's nothing yet.
class _JobTimeline extends StatelessWidget {
  const _JobTimeline({required this.jobId});
  final String jobId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<List<JobEvent>>(
      stream: context.read<JobRepository>().watchJobEvents(jobId),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const AppCard(
            child: EmptyState(
              icon: Icons.error_outline,
              title: "Couldn't load your activity",
              message: 'Please check your connection and try again.',
            ),
          );
        }
        final events = snapshot.data ?? [];
        if (events.isEmpty) return const SizedBox.shrink();
        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Activity', style: theme.textTheme.titleLarge),
              const SizedBox(height: 12),
              for (final (i, event) in events.indexed)
                Padding(
                  padding:
                      EdgeInsets.only(bottom: i == events.length - 1 ? 0 : 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(_timelineIcon(event.type),
                          size: 18, color: _timelineColor(context, event.type)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(event.title, style: theme.textTheme.bodyMedium),
                            Text(timeAgo(event.at),
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// How the requestor orders the bid list. `bestValue` (the default) blends
/// price and Trust Score; the other two sort on a single dimension.
enum _BidSort { bestValue, price, trustScore }

/// The "Best Value" composite for [bid] (plan §3.2.3): a price score of 1.0 for
/// the cheapest bid scaling down for pricier ones, blended with the provider's
/// normalised Trust Score. Higher is better. [lowestSen] is the cheapest bid in
/// the list, so callers compute it once and share it.
double _compositeScore(Bid bid, int lowestSen) {
  final priceScore = lowestSen / bid.amountSen;
  final trust = bid.providerTrustScore / 1000;
  return PlatformConfig.priceWeight * priceScore +
      PlatformConfig.trustWeight * trust;
}

/// Requestor view: the live bid list with a sort toggle and Accept actions
/// while the job is open; the assigned provider once it's in progress.
class _RequestorSection extends StatefulWidget {
  const _RequestorSection({required this.job});
  final Job job;

  @override
  State<_RequestorSection> createState() => _RequestorSectionState();
}

class _RequestorSectionState extends State<_RequestorSection> {
  _BidSort _sort = _BidSort.bestValue;

  // Cached so changing the sort (a setState) re-orders the already-loaded bids
  // client-side instead of resubscribing to Firestore and flashing the spinner.
  late final Stream<List<Bid>> _bids =
      context.read<BidRepository>().watchBids(widget.job.id);

  Future<void> _accept(Bid bid) async {
    final available =
        context.read<AuthController>().user?.availableBalanceSen;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Accept this bid?'),
        content: Text(
            '${bid.providerName} will be assigned to "${widget.job.title}" '
            'for ${formatRm(bid.amountSen)}. Other bids will be declined.'
            '${available != null ? '\n\nYour available balance: '
                '${formatRm(available)}.' : ''}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Accept Bid'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await context.read<BidRepository>().acceptBid(bid);
    } on InsufficientBalanceException catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Not enough balance'),
          content: Text('You need ${formatRm(e.shortfallSen)} more available '
              'to accept this bid (available: ${formatRm(e.availableSen)}, '
              'required: ${formatRm(e.requiredSen)}).'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop();
                context.push('/profile/earnings');
              },
              child: const Text('Top up'),
            ),
          ],
        ),
      );
    } on BidAcceptRaceException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('This job changed — please review the current bids '
              'and try again.')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not accept the bid. Please try again.')));
    }
  }

  /// Cancels the still-open job after confirmation. Once the status leaves
  /// `open`, the rules already block new bids and the job drops out of the
  /// browse feeds.
  Future<void> _cancelJob() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel this job?'),
        content: const Text(
            'Your job posting will be closed and providers will no longer '
            'be able to bid. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep Job'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: context.fairbid.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel Job'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await context.read<JobRepository>().cancelOpenJob(widget.job.id);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not cancel the job. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final job = widget.job;

    if (job.status != JobStatus.open) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AssignedProviderCard(job: job),
          if (job.acceptedProviderId != null) ...[
            const SizedBox(height: 16),
            JobAddressCard(job: job, isOwner: true),
            const SizedBox(height: 16),
            // Funding/releasing milestones is what completes the job now —
            // no manual "mark complete" button.
            MilestoneSection(job: job),
            if (job.status == JobStatus.inProgress) ...[
              const SizedBox(height: 16),
              _CancellationSection(job: job),
            ],
            if (job.status == JobStatus.completed) ...[
              const SizedBox(height: 16),
              _LeaveReviewCard(
                job: job,
                revieweeId: job.acceptedProviderId!,
                revieweeName: job.acceptedProviderName ?? 'Provider',
              ),
            ],
          ],
        ],
      );
    }

    final bidList = StreamBuilder<List<Bid>>(
      stream: _bids,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return const AppCard(
            child: EmptyState(
              icon: Icons.error_outline,
              title: "Couldn't load bids",
              message: 'Please check your connection and try again.',
            ),
          );
        }
        final bids = (snapshot.data ?? [])
            .where((b) => b.status == BidStatus.pending)
            .toList();

        if (bids.isEmpty) {
          return const AppCard(
            child: EmptyState(
              icon: Icons.gavel_rounded,
              title: 'No bids yet',
              message: 'Providers\' bids will appear here as they come in — '
                  'you\'ll compare and accept one.',
            ),
          );
        }

        // Composite needs the cheapest bid; compute it once and share it with
        // the sort and the Best Value badge so all three agree.
        final lowestSen = bids.map((b) => b.amountSen).reduce(min);
        bids.sort(switch (_sort) {
          _BidSort.price => (a, b) => a.amountSen.compareTo(b.amountSen),
          _BidSort.trustScore => (a, b) =>
              b.providerTrustScore.compareTo(a.providerTrustScore),
          _BidSort.bestValue => (a, b) => _compositeScore(b, lowestSen)
              .compareTo(_compositeScore(a, lowestSen)),
        });
        // The single Best Value bid, badged regardless of the current sort.
        final bestValueId = bids
            .reduce((a, b) => _compositeScore(a, lowestSen) >=
                    _compositeScore(b, lowestSen)
                ? a
                : b)
            .providerId;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Bids (${bids.length})', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<_BidSort>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                      value: _BidSort.bestValue, label: Text('Best')),
                  ButtonSegment(
                      value: _BidSort.price, label: Text('Price')),
                  ButtonSegment(
                      value: _BidSort.trustScore, label: Text('Trust')),
                ],
                selected: {_sort},
                onSelectionChanged: (s) => setState(() => _sort = s.first),
              ),
            ),
            const SizedBox(height: 12),
            for (final bid in bids)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: BidCard(
                  bid: bid,
                  isBestValue: bid.providerId == bestValueId,
                  onAccept: () => _accept(bid),
                ),
              ),
          ],
        );
      },
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        bidList,
        const SizedBox(height: 8),
        TextButton(
          onPressed: _cancelJob,
          style: TextButton.styleFrom(
            foregroundColor: context.fairbid.danger,
            minimumSize: const Size.fromHeight(44),
          ),
          child: const Text('Cancel Job'),
        ),
      ],
    );
  }
}

/// A prompt to review the counterparty on a completed job. Opens the review
/// sheet and, once a review is left, swaps itself for a thank-you note.
class _LeaveReviewCard extends StatefulWidget {
  const _LeaveReviewCard({
    required this.job,
    required this.revieweeId,
    required this.revieweeName,
  });
  final Job job;
  final String revieweeId;
  final String revieweeName;

  @override
  State<_LeaveReviewCard> createState() => _LeaveReviewCardState();
}

class _LeaveReviewCardState extends State<_LeaveReviewCard> {
  bool _submitted = false;

  Future<void> _open() async {
    final me = context.read<AuthController>().user;
    if (me == null) return;
    final ok = await LeaveReviewSheet.show(
      context,
      job: widget.job,
      reviewer: me,
      revieweeId: widget.revieweeId,
      revieweeName: widget.revieweeName,
    );
    if (ok == true && mounted) setState(() => _submitted = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_submitted) {
      return InfoBanner(
        icon: Icons.check_circle_outline,
        title: 'Review submitted',
        body: 'Thanks — your feedback helps keep FairBid fair.',
        color: context.fairbid.success,
      );
    }
    return PrimaryButton(
      label: 'Review ${widget.revieweeName}',
      trailingIcon: Icons.star_outline,
      onPressed: _open,
    );
  }
}

/// The winner card shown to both sides once a job is no longer open. The two
/// chat participants (requestor and accepted provider) also get a message
/// button that opens the job's conversation.
class _AssignedProviderCard extends StatelessWidget {
  const _AssignedProviderCard({required this.job});
  final Job job;

  Future<void> _openChat(BuildContext context) async {
    try {
      final id = await context.read<ChatRepository>().openConversation(job);
      if (!context.mounted) return;
      context.push('/messages/$id');
    } catch (_) {
      if (!context.mounted) return;
      // Collapse repeats: a stale snackbar from an earlier failed tap would
      // otherwise queue behind this one and show the same error twice.
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
            content: Text('Could not open the chat. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (job.acceptedProviderName == null) {
      return AppCard(
        child: EmptyState(
          icon: Icons.gavel_rounded,
          title: 'Bidding closed',
          message: 'This job is no longer accepting bids.',
        ),
      );
    }
    final myUid = context.read<AuthController>().user?.uid;
    final canChat = myUid != null &&
        job.acceptedProviderId != null &&
        (myUid == job.requestorId || myUid == job.acceptedProviderId);
    return AppCard(
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: context.fairbid.subtleBlue,
            child: Icon(Icons.handyman_outlined,
                color: context.fairbid.verified),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Assigned Provider', style: theme.textTheme.labelMedium),
                Text(job.acceptedProviderName!,
                    style: theme.textTheme.titleLarge),
                if (job.acceptedBidAmountSen != null)
                  Text('Accepted bid: ${formatRm(job.acceptedBidAmountSen!)}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          if (canChat)
            IconButton(
              tooltip: 'Message',
              icon: Icon(Icons.chat_bubble_outline,
                  color: context.fairbid.verified),
              onPressed: () => _openChat(context),
            ),
        ],
      ),
    );
  }
}

/// Provider view: the client card, then — on an open job — the bid action for
/// their verification state (locked / submit / withdraw).
class _ProviderSection extends StatelessWidget {
  const _ProviderSection({required this.job});
  final Job job;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = context.watch<AuthController>().user;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: context.fairbid.subtleBlue,
                child: Icon(Icons.person_outline,
                    color: context.fairbid.verified),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Client', style: theme.textTheme.labelMedium),
                    Text(job.requestorName,
                        style: theme.textTheme.titleLarge),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (job.status != JobStatus.open)
          _ProviderAssignedView(job: job, user: user)
        else if (user == null || user.verificationStatus != 'approved')
          const InfoBanner(
            icon: Icons.lock_outline,
            title: 'Bidding locked',
            body: 'Bidding unlocks once an admin approves your verification '
                'documents.',
          )
        else
          _BidAction(job: job, user: user),
      ],
    );
  }
}

/// Provider's view of a job that's no longer open: the winner card, the
/// milestone plan (propose/deliver actions) for the accepted provider, plus —
/// on a completed job — a prompt to review the requestor.
class _ProviderAssignedView extends StatelessWidget {
  const _ProviderAssignedView({required this.job, required this.user});
  final Job job;
  final AppUser? user;

  @override
  Widget build(BuildContext context) {
    final isAssigned = user != null && job.acceptedProviderId == user!.uid;
    final canReview = job.status == JobStatus.completed && isAssigned;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AssignedProviderCard(job: job),
        if (isAssigned) ...[
          const SizedBox(height: 16),
          JobAddressCard(job: job, isOwner: false),
          const SizedBox(height: 16),
          MilestoneSection(job: job),
          if (job.status == JobStatus.inProgress) ...[
            const SizedBox(height: 16),
            _CancellationSection(job: job),
          ],
        ],
        if (canReview) ...[
          const SizedBox(height: 16),
          _LeaveReviewCard(
            job: job,
            revieweeId: job.requestorId,
            revieweeName: job.requestorName,
          ),
        ],
      ],
    );
  }
}

/// Submit-or-withdraw, driven by whether the provider already has a live bid.
class _BidAction extends StatelessWidget {
  const _BidAction({required this.job, required this.user});
  final Job job;
  final AppUser user;

  Future<void> _withdraw(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Withdraw your bid?'),
        content: const Text(
            'Your bid will be removed from this job. You can bid again while '
            'the job is still open.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Withdraw'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await context.read<BidRepository>().withdrawBid(job.id, user.uid);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bid withdrawn.')));
    } on BidNotPendingException {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('This bid was just accepted or resolved.')));
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not withdraw the bid. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<Bid?>(
      stream: context.read<BidRepository>().watchMyBid(job.id, user.uid),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return const AppCard(
            child: EmptyState(
              icon: Icons.error_outline,
              title: "Couldn't load your bid",
              message: 'Please check your connection and try again.',
            ),
          );
        }
        final bid = snapshot.data;
        if (bid == null) {
          // The server may lag closing the job at its deadline (that's the
          // closeExpiredJobs sweep's job), so gate the submit button on the
          // deadline directly rather than trusting job.status alone.
          if (job.deadline != null && job.deadline!.isBefore(DateTime.now())) {
            return const InfoBanner(
              icon: Icons.timer_off_outlined,
              title: 'Bidding closed',
              body: 'Bidding for this job has closed.',
            );
          }
          return PrimaryButton(
            label: 'Submit a bid',
            onPressed: () =>
                SubmitBidSheet.show(context, job: job, bidder: user),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Your bid', style: theme.textTheme.labelMedium),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(formatRm(bid.amountSen),
                            style: theme.textTheme.titleLarge?.copyWith(
                                color: context.fairbid.verified)),
                      ),
                      Text(bid.estimatedDuration,
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SecondaryButton(
              label: 'Withdraw bid',
              onPressed: () => _withdraw(context),
            ),
          ],
        );
      },
    );
  }
}

/// Mutual mid-flight cancellation for an in-progress job. Either participant
/// requests; the counterparty accepts (which cancels) or declines. The server
/// refuses while escrow is held, so the message from a blocked attempt is
/// surfaced verbatim. Shown to participants only.
class _CancellationSection extends StatefulWidget {
  const _CancellationSection({required this.job});
  final Job job;

  @override
  State<_CancellationSection> createState() => _CancellationSectionState();
}

class _CancellationSectionState extends State<_CancellationSection> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(e.message ?? 'Something went wrong. Please try again.')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Something went wrong. Please try again.')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _request() async {
    final reason = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Request cancellation?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('The other party must agree before the job is '
                'cancelled. Funded milestones must be released or disputed '
                'first.'),
            const SizedBox(height: 12),
            TextField(
              controller: reason,
              maxLines: 3,
              decoration: const InputDecoration(hintText: 'Reason (optional)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Request'),
          ),
        ],
      ),
    );
    final text = reason.text.trim();
    reason.dispose();
    if (confirmed != true || !mounted) return;
    final repo = context.read<JobRepository>();
    await _run(() => repo.requestCancellation(widget.job.id,
        reason: text.isEmpty ? null : text));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final myUid = context.read<AuthController>().user?.uid;
    final job = widget.job;
    final myRole = myUid == job.requestorId
        ? 'requestor'
        : myUid == job.acceptedProviderId
            ? 'provider'
            : null;
    if (myRole == null) return const SizedBox.shrink();

    if (!job.hasPendingCancellation) {
      return Center(
        child: TextButton.icon(
          onPressed: _busy ? null : _request,
          style: TextButton.styleFrom(foregroundColor: context.fairbid.danger),
          icon: const Icon(Icons.cancel_outlined, size: 18),
          label: const Text('Request cancellation'),
        ),
      );
    }

    final iRequested = job.cancellationRequestedBy == myRole;
    final reason = job.cancellationReason;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            iRequested
                ? 'Cancellation requested'
                : 'The other party wants to cancel',
            style: theme.textTheme.titleMedium,
          ),
          if (reason != null && reason.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('"$reason"',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
          const SizedBox(height: 12),
          if (iRequested)
            Text('Waiting for the other party to respond.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant))
          else ...[
            PrimaryButton(
              label: 'Accept & Cancel Job',
              busy: _busy,
              onPressed: () {
                final repo = context.read<JobRepository>();
                _run(() =>
                    repo.respondToCancellation(job.id, accept: true));
              },
            ),
            const SizedBox(height: 8),
            SecondaryButton(
              label: 'Decline',
              onPressed: _busy
                  ? null
                  : () {
                      final repo = context.read<JobRepository>();
                      _run(() => repo.respondToCancellation(job.id,
                          accept: false));
                    },
            ),
          ],
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(
      {required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text('$label: ',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          Expanded(
              child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
