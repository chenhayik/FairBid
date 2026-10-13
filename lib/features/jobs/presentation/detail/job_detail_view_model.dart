import '../../../../core/util/money.dart';
import '../../../../core/util/plural.dart';
import '../../../auth/domain/app_user.dart';
import '../../../auth/domain/user_role.dart';
import '../../domain/bid.dart';
import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';

/// What:   The viewer's relationship to a job.
/// Input:  Resolved by _resolveRole() from the job, signed-in user and own bid.
/// Output: Decides which sections show and which bar action is offered.
enum JobViewerRole {
  owner,

  acceptedProvider,

  /// Has a pending bid on a still-open job.
  bidder,

  /// Looking at a still-open job without a bid on it.
  browser,

  /// A losing bidder or stranger once the job is no longer open.
  outsider,
}

/// What:   Names what the bottom bar's button does.
/// Input:  Set on [NextAction.kind] by the _for* builders below.
/// Output: _handleAction() in job_detail_screen.dart maps each kind to a callback.
enum JobActionKind {
  /// Scrolls to the bid list (owner) or the viewer's own bid (bidder).
  compareBids,

  /// Opens the chat thread with the counterparty.
  message,

  /// Opens the review sheet.
  leaveReview,

  /// Opens the submit-a-bid sheet.
  submitBid,

  /// Deep-links into provider onboarding/verification.
  getVerified,

  /// Opens the submit-a-bid sheet prefilled with the viewer's own bid.
  editBid,

  /// Marks the current milestone delivered (with confirmation).
  markDelivered,

  /// Releases the current milestone (with confirmation).
  releaseMilestone,

  /// Opens the sheet to propose visit times.
  proposeTime,

  /// Confirms the other party's proposed visit time.
  confirmTime,

  /// Opens the bundle's award screen, where a still-open live bundle task's
  /// bids are compared rather than in this job's own (empty) bid list.
  viewBundle,
}

/// What:   The bottom bar's call to action.
/// Input:  Built by the _for* builders below.
/// Output: Button [label], what it does ([kind]) and an optional [contextLine].
class NextAction {
  const NextAction({
    required this.label,
    required this.kind,
    this.contextLine,
  });

  final String label;
  final JobActionKind kind;
  final String? contextLine;
}

/// What:   Widget-free view of one job for one viewer.
/// Input:  Built by buildJobDetailVm() from job, signed-in user, own bid and bundle bid.
/// Output: Role, headline, the bar's action or waiting line, and which sections show.
class JobDetailViewModel {
  const JobDetailViewModel({
    required this.role,
    required this.statusHeadline,
    this.primaryAction,
    this.waitingLine,
    this.showBids = false,
    this.showMilestones = false,
    this.showAddress = false,
    this.showReviewPrompt = false,
    this.showCancel = false,
    this.showCancellationResponse = false,
    this.showPriceChangeCard = false,
  });

  final JobViewerRole role;

  /// One sentence on whose turn it is, or what just happened.
  final String statusHeadline;

  /// Null hides the bar button (or [waitingLine] shows instead).
  final NextAction? primaryAction;

  /// Muted bar text when it's the other party's move; never with [primaryAction].
  final String? waitingLine;

  /// The bid list (owner) or the submit/withdraw bid action (provider).
  final bool showBids;

  /// The milestone tracker.
  final bool showMilestones;

  /// The private service address card and the message entry.
  final bool showAddress;

  /// The leave-a-review prompt.
  final bool showReviewPrompt;

  /// Whether "Cancel job" / "Ask to cancel the job" belongs in the problem sheet.
  final bool showCancel;

  /// A cancellation request is waiting for this viewer's answer.
  final bool showCancellationResponse;

  /// A price change is pending: the responder gets Accept/Decline, the proposer Withdraw.
  final bool showPriceChangeCard;
}

/// What:   Builds the view model for [me] looking at [job].
/// Input:  [myBid] if they bid; [myBundleBid] for a live bundle task (which has no per-job bid).
/// Output: A [JobDetailViewModel]; pure, so tests cover the role x status matrix directly.
JobDetailViewModel buildJobDetailVm(
  Job job,
  AppUser? me,
  Bid? myBid, {
  BundleBid? myBundleBid,
}) {
  return switch (_resolveRole(job, me, myBid)) {
    JobViewerRole.owner => _forOwner(job),
    JobViewerRole.acceptedProvider => _forAcceptedProvider(job),
    JobViewerRole.bidder => _forBidder(job, myBid!),
    JobViewerRole.browser => _forBrowser(job, me, myBundleBid),
    JobViewerRole.outsider => _forOutsider(job),
  };
}

JobViewerRole _resolveRole(Job job, AppUser? me, Bid? myBid) {
  if (me != null && me.uid == job.requestorId) return JobViewerRole.owner;
  if (me != null &&
      job.acceptedProviderId != null &&
      me.uid == job.acceptedProviderId) {
    return JobViewerRole.acceptedProvider;
  }
  if (job.status == JobStatus.open) {
    if (myBid != null && myBid.status == BidStatus.pending) {
      return JobViewerRole.bidder;
    }
    return JobViewerRole.browser;
  }
  return JobViewerRole.outsider;
}

JobDetailViewModel _forOwner(Job job) {
  final hasProvider = job.acceptedProviderId != null;
  final showAddress = hasProvider;
  final showMilestones =
      hasProvider &&
      (job.status == JobStatus.inProgress || job.status == JobStatus.completed);

  switch (job.status) {
    case JobStatus.open:
      final n = job.bidCount;
      // bidCount on a live bundle task counts package bids on the whole bundle.
      if (job.isLiveBundleTask) {
        return JobDetailViewModel(
          role: JobViewerRole.owner,
          statusHeadline: n > 0
              ? '${plural(n, 'bundle bid')} ${n == 1 ? 'covers' : 'cover'} this task.'
              : 'Waiting for providers to bid on this bundle.',
          primaryAction: const NextAction(
            label: 'View bundle',
            kind: JobActionKind.viewBundle,
          ),
          waitingLine: n > 0 ? null : 'No bids yet. Check back soon.',
          showCancel: true,
        );
      }
      return JobDetailViewModel(
        role: JobViewerRole.owner,
        statusHeadline: n > 0
            ? 'You have $n bid${n == 1 ? '' : 's'} to review.'
            : 'Waiting for providers to bid on this job.',
        primaryAction: n > 0
            ? NextAction(
                label: n == 1 ? 'View 1 bid' : 'Compare $n bids',
                kind: JobActionKind.compareBids,
                contextLine: job.budget?.label ?? job.location.address,
              )
            : null,
        waitingLine: n > 0 ? null : 'No bids yet. Check back soon.',
        showBids: true,
        showCancel: true,
      );
    case JobStatus.inProgress:
      final providerName = job.acceptedProviderName ?? 'Your provider';
      return JobDetailViewModel(
        role: JobViewerRole.owner,
        statusHeadline: job.hasPendingCancellation
            ? 'A cancellation request needs your response.'
            : job.priceChangeRequest?.by == 'provider'
            ? 'A price change request needs your response.'
            : job.needsAppointment
            ? 'Agree a visit time with $providerName.'
            : '$providerName is on the job. Your payment is secured in '
                  'escrow; release it once the work is done.',
        primaryAction: const NextAction(
          label: 'Message provider',
          kind: JobActionKind.message,
        ),
        showMilestones: showMilestones,
        showAddress: showAddress,
        showCancel: true,
        showCancellationResponse: job.hasPendingCancellation,
        showPriceChangeCard: job.hasPendingPriceChange,
      );
    case JobStatus.completed:
      final providerName = job.acceptedProviderName ?? 'your provider';
      return JobDetailViewModel(
        role: JobViewerRole.owner,
        statusHeadline: 'Job completed. Leave a review for $providerName.',
        primaryAction: NextAction(
          label: 'Review ${job.acceptedProviderName ?? 'provider'}',
          kind: JobActionKind.leaveReview,
          contextLine: job.title,
        ),
        showMilestones: showMilestones,
        showAddress: showAddress,
        showReviewPrompt: true,
      );
    case JobStatus.cancelled:
      return JobDetailViewModel(
        role: JobViewerRole.owner,
        statusHeadline: job.cancelledBy == 'dispute'
            ? 'This job ended after a dispute. The money held was refunded '
                  'to you.'
            : 'This job was cancelled.',
        showAddress: showAddress,
      );
  }
}

JobDetailViewModel _forAcceptedProvider(Job job) {
  switch (job.status) {
    case JobStatus.inProgress:
      return JobDetailViewModel(
        role: JobViewerRole.acceptedProvider,
        statusHeadline: job.hasPendingCancellation
            ? 'A cancellation request needs your response.'
            : job.priceChangeRequest?.by == 'requestor'
            ? 'A price change request needs your response.'
            : job.needsAppointment
            ? 'Agree a visit time with ${job.requestorName}.'
            : "You're working on \"${job.title}\" for "
                  '${job.requestorName}.',
        primaryAction: const NextAction(
          label: 'Message client',
          kind: JobActionKind.message,
        ),
        showMilestones: true,
        showAddress: true,
        showCancel: true,
        showCancellationResponse: job.hasPendingCancellation,
        showPriceChangeCard: job.hasPendingPriceChange,
      );
    case JobStatus.completed:
      return JobDetailViewModel(
        role: JobViewerRole.acceptedProvider,
        statusHeadline:
            'Job completed. Leave a review for ${job.requestorName}.',
        primaryAction: NextAction(
          label: 'Review ${job.requestorName}',
          kind: JobActionKind.leaveReview,
          contextLine: job.title,
        ),
        showMilestones: true,
        showAddress: true,
        showReviewPrompt: true,
      );
    case JobStatus.cancelled:
      return JobDetailViewModel(
        role: JobViewerRole.acceptedProvider,
        statusHeadline: job.cancelledBy == 'dispute'
            ? 'This job ended after a dispute. An admin refunded the client.'
            : 'This job was cancelled.',
        showAddress: true,
      );
    case JobStatus.open:
      // Unreachable (an accepted provider means the job left `open`); needed for exhaustiveness.
      return const JobDetailViewModel(
        role: JobViewerRole.acceptedProvider,
        statusHeadline: 'You are assigned to this job.',
        showAddress: true,
      );
  }
}

JobDetailViewModel _forBidder(Job job, Bid myBid) {
  final deadlinePassed =
      job.deadline != null && job.deadline!.isBefore(DateTime.now());
  return JobDetailViewModel(
    role: JobViewerRole.bidder,
    statusHeadline:
        'Your bid of ${formatRm(myBid.amountSen)} is waiting '
        'for ${job.requestorName} to decide.',
    // No edit once bidding has closed.
    primaryAction: deadlinePassed
        ? null
        : NextAction(
            label: 'Edit bid',
            kind: JobActionKind.editBid,
            contextLine:
                '${formatRm(myBid.amountSen)} - ${myBid.estimatedDuration}',
          ),
    showBids: true,
  );
}

JobDetailViewModel _forBrowser(Job job, AppUser? me, BundleBid? myBundleBid) {
  final isProvider = me?.role == UserRole.provider;
  final verified = me?.verificationStatus == 'approved';
  final deadlinePassed =
      job.deadline != null && job.deadline!.isBefore(DateTime.now());

  // Checked first: a package bid leaves the provider a plain browser here.
  if (isProvider &&
      job.isLiveBundleTask &&
      myBundleBid != null &&
      myBundleBid.status == BundleBidStatus.pending &&
      myBundleBid.coversTask(job.id)) {
    final price = myBundleBid.priceFor(job.id)!;
    return JobDetailViewModel(
      role: JobViewerRole.browser,
      statusHeadline: 'You bid ${formatRm(price)} on this task as part of '
          'a bundle bid.',
      primaryAction: const NextAction(
        label: 'Edit bundle bid',
        kind: JobActionKind.submitBid,
      ),
      // The screen shows a "Your bundle bid" card instead of "Submit a bid".
    );
  }

  // A pending bundle bid that misses this task is still edited via the sheet.
  final editsBundleBid = isProvider &&
      job.isLiveBundleTask &&
      myBundleBid != null &&
      myBundleBid.status == BundleBidStatus.pending;

  final String headline;
  NextAction? action;
  if (!isProvider) {
    headline = 'This job is open for bids.';
  } else if (!verified) {
    headline = 'Get verified to start bidding on jobs like this.';
    action = const NextAction(
      label: 'Get verified to bid',
      kind: JobActionKind.getVerified,
    );
  } else if (deadlinePassed) {
    headline = "This job's bidding window has ended.";
  } else {
    headline = editsBundleBid
        ? "Your bundle bid doesn't include this task yet. "
            'Edit it to add this task.'
        : 'Review the job, then submit your bid.';
    action = NextAction(
      label: editsBundleBid
          ? 'Edit bundle bid'
          : job.isLiveBundleTask
              ? 'Bid on this bundle'
              : 'Submit a bid',
      kind: JobActionKind.submitBid,
      contextLine: job.budget?.label ?? job.location.address,
    );
  }

  return JobDetailViewModel(
    role: JobViewerRole.browser,
    statusHeadline: headline,
    primaryAction: action,
    showBids: true,
  );
}

JobDetailViewModel _forOutsider(Job job) {
  return JobDetailViewModel(
    role: JobViewerRole.outsider,
    statusHeadline: job.status == JobStatus.cancelled
        ? 'This job was cancelled.'
        : 'This job is no longer open for bids.',
  );
}
