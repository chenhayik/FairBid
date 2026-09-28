import '../../../../core/util/money.dart';
import '../../../auth/domain/app_user.dart';
import '../../../auth/domain/user_role.dart';
import '../../domain/bid.dart';
import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';

/// Who is looking at a job detail screen, resolved from the job and the
/// signed-in user (plus their own bid, when they have one). Drives which
/// slots the body shows and which single action the bottom bar offers.
enum JobViewerRole {
  /// The requestor who posted the job.
  owner,

  /// The provider whose bid was accepted.
  acceptedProvider,

  /// A provider with a live (pending) bid on a still-open job.
  bidder,

  /// A provider (or anyone else) looking at a still-open job without a bid
  /// on it yet.
  browser,

  /// Nobody in particular: a losing bidder once the job has moved on, or a
  /// stranger to a job that's no longer open. Nothing to do here.
  outsider,
}

/// The single thing [JobDetailViewModel.primaryAction] does when tapped.
/// The widget layer owns the actual callback for each kind - this only
/// names *what* happens, keeping the view model itself widget-free.
enum JobActionKind {
  /// Scrolls to the bid list (owner) or the viewer's own bid (bidder).
  compareBids,

  /// Opens the chat thread with the counterparty.
  message,

  /// Scrolls to the leave-a-review prompt.
  leaveReview,

  /// Opens the submit-a-bid sheet.
  submitBid,

  /// Deep-links into provider onboarding/verification.
  getVerified,

  /// Scrolls to the viewer's own bid (paired with a secondary Withdraw).
  yourBid,

  /// Scrolls to the milestone tracker to propose a plan.
  proposeMilestones,

  /// Scrolls to the milestone tracker to mark the current milestone
  /// delivered.
  markDelivered,

  /// Scrolls to the milestone tracker to fund the current milestone.
  fundMilestone,

  /// Scrolls to the milestone tracker to release the current milestone.
  releaseMilestone,

  /// Scrolls to the milestone tracker to approve/request changes on a
  /// proposed plan.
  reviewPlan,

  /// Opens the bundle's award screen, where a still-open live bundle task's
  /// bids are compared rather than in this job's own (empty) bid list.
  viewBundle,
}

/// A role-resolved call to action: a label, what it does ([kind]), an
/// optional short money/context line shown alongside it, and - for the
/// bidder's "Your bid RM X" - an optional secondary label (Withdraw).
class NextAction {
  const NextAction({
    required this.label,
    required this.kind,
    this.contextLine,
    this.secondaryLabel,
  });

  final String label;
  final JobActionKind kind;
  final String? contextLine;
  final String? secondaryLabel;
}

/// The pure, widget-free result of looking at one job as one viewer: what
/// role they're in, a one-sentence summary of whose turn it is, the single
/// action they can take right now (if any), and which body slots apply to
/// them. Built by [buildJobDetailVm] - see that function for how the
/// role/status matrix maps onto these fields.
class JobDetailViewModel {
  const JobDetailViewModel({
    required this.role,
    required this.statusHeadline,
    this.primaryAction,
    this.waitingLine,
    required this.showBids,
    required this.showMilestones,
    required this.showAddress,
    required this.showReviewPrompt,
    required this.showCancel,
    this.showCancellationResponse = false,
  });

  final JobViewerRole role;

  /// One plain-language sentence for the status headline strip: whose turn
  /// it is, or what just happened.
  final String statusHeadline;

  /// The bottom bar's single CTA, or null when the viewer has nothing to do
  /// (the bar hides) or a muted [waitingLine] should show instead.
  final NextAction? primaryAction;

  /// A muted status line for the bottom bar when it's the other party's
  /// move - shown instead of [primaryAction], never both.
  final String? waitingLine;

  /// Slot 7: the bid list (owner) or the submit/withdraw bid action
  /// (provider). True exactly while the job is open.
  final bool showBids;

  /// Slot 8: the milestone tracker.
  final bool showMilestones;

  /// Slot 9: the private service address card and the message/chat entry.
  final bool showAddress;

  /// Slot 10: the leave-a-review prompt.
  final bool showReviewPrompt;

  /// Whether a cancel-related menu entry belongs in the app bar's overflow
  /// menu ("Cancel job" while open, "Request cancellation" while in
  /// progress). The exact label is resolved from [role] and the job's own
  /// status by the widget layer, which already has both.
  final bool showCancel;

  /// Slot 3: a mid-flight cancellation request is outstanding and needs
  /// this viewer's response.
  final bool showCancellationResponse;
}

/// Builds the [JobDetailViewModel] for [me] looking at [job], with [myBid]
/// set when they've already bid, and [myBundleBid] their package bid when
/// [job] is a live bundle task (which never has a per-job [myBid]). Pure and
/// widget-free - safe to unit test over the role x status matrix directly.
JobDetailViewModel buildJobDetailVm(
  Job job,
  AppUser? me,
  Bid? myBid, {
  BundleBid? myBundleBid,
}) {
  switch (_resolveRole(job, me, myBid)) {
    case JobViewerRole.owner:
      return _forOwner(job);
    case JobViewerRole.acceptedProvider:
      return _forAcceptedProvider(job);
    case JobViewerRole.bidder:
      return _forBidder(job, myBid!);
    case JobViewerRole.browser:
      return _forBrowser(job, me, myBundleBid);
    case JobViewerRole.outsider:
      return _forOutsider(job);
  }
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
      // A live bundle task's `bidCount` counts package bids on the whole
      // bundle, so it gets its own headline/action pointing at that screen.
      if (job.isLiveBundleTask) {
        return JobDetailViewModel(
          role: JobViewerRole.owner,
          statusHeadline: n > 0
              ? '$n package bid${n == 1 ? '' : 's'} cover this task.'
              : 'Waiting for providers to bid on this bundle.',
          primaryAction: const NextAction(
            label: 'View bundle',
            kind: JobActionKind.viewBundle,
          ),
          waitingLine: n > 0 ? null : 'No bids yet. Check back soon.',
          showBids: false,
          showMilestones: false,
          showAddress: false,
          showReviewPrompt: false,
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
                label: 'Compare $n bid${n == 1 ? '' : 's'}',
                kind: JobActionKind.compareBids,
                contextLine: job.budget?.label ?? job.location.address,
              )
            : null,
        waitingLine: n > 0 ? null : 'No bids yet. Check back soon.',
        showBids: true,
        showMilestones: false,
        showAddress: false,
        showReviewPrompt: false,
        showCancel: true,
      );
    case JobStatus.inProgress:
      final providerName = job.acceptedProviderName ?? 'Your provider';
      return JobDetailViewModel(
        role: JobViewerRole.owner,
        statusHeadline: job.hasPendingCancellation
            ? 'A cancellation request needs your response.'
            : '$providerName is on the job. Fund and release each '
                  'milestone as work is approved.',
        primaryAction: const NextAction(
          label: 'Message provider',
          kind: JobActionKind.message,
        ),
        showBids: false,
        showMilestones: showMilestones,
        showAddress: showAddress,
        showReviewPrompt: false,
        showCancel: true,
        showCancellationResponse: job.hasPendingCancellation,
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
        showBids: false,
        showMilestones: showMilestones,
        showAddress: showAddress,
        showReviewPrompt: true,
        showCancel: false,
      );
    case JobStatus.cancelled:
      return JobDetailViewModel(
        role: JobViewerRole.owner,
        statusHeadline: 'This job was cancelled.',
        showBids: false,
        showMilestones: false,
        showAddress: showAddress,
        showReviewPrompt: false,
        showCancel: false,
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
            : "You're working on \"${job.title}\" for "
                  '${job.requestorName}.',
        primaryAction: const NextAction(
          label: 'Message client',
          kind: JobActionKind.message,
        ),
        showBids: false,
        showMilestones: true,
        showAddress: true,
        showReviewPrompt: false,
        showCancel: true,
        showCancellationResponse: job.hasPendingCancellation,
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
        showBids: false,
        showMilestones: true,
        showAddress: true,
        showReviewPrompt: true,
        showCancel: false,
      );
    case JobStatus.cancelled:
      return const JobDetailViewModel(
        role: JobViewerRole.acceptedProvider,
        statusHeadline: 'This job was cancelled.',
        showBids: false,
        showMilestones: false,
        showAddress: true,
        showReviewPrompt: false,
        showCancel: false,
      );
    case JobStatus.open:
      // Unreachable in practice - an accepted provider implies the job left
      // `open` - but every JobStatus needs a branch, so fail safe rather
      // than throw.
      return const JobDetailViewModel(
        role: JobViewerRole.acceptedProvider,
        statusHeadline: 'You are assigned to this job.',
        showBids: false,
        showMilestones: false,
        showAddress: true,
        showReviewPrompt: false,
        showCancel: false,
      );
  }
}

JobDetailViewModel _forBidder(Job job, Bid myBid) {
  return JobDetailViewModel(
    role: JobViewerRole.bidder,
    statusHeadline:
        'Your bid of ${formatRm(myBid.amountSen)} is waiting '
        'for ${job.requestorName} to decide.',
    primaryAction: NextAction(
      label: 'Your bid ${formatRm(myBid.amountSen)}',
      kind: JobActionKind.yourBid,
      contextLine: myBid.estimatedDuration,
      secondaryLabel: 'Withdraw',
    ),
    showBids: true,
    showMilestones: false,
    showAddress: false,
    showReviewPrompt: false,
    showCancel: false,
  );
}

JobDetailViewModel _forBrowser(Job job, AppUser? me, BundleBid? myBundleBid) {
  final isProvider = me?.role == UserRole.provider;
  final verified = me?.verificationStatus == 'approved';
  final deadlinePassed =
      job.deadline != null && job.deadline!.isBefore(DateTime.now());

  // A live bundle task never has a per-job bid, so a provider who already
  // covered it via a package bid still resolves as a plain browser - check
  // this first, ahead of the verified/deadline gates they already cleared.
  if (isProvider &&
      job.isLiveBundleTask &&
      myBundleBid != null &&
      myBundleBid.status == BundleBidStatus.pending &&
      myBundleBid.coversTask(job.id)) {
    final price = myBundleBid.priceFor(job.id)!;
    return JobDetailViewModel(
      role: JobViewerRole.browser,
      statusHeadline: 'You bid ${formatRm(price)} on this task as part of '
          'a package bid.',
      primaryAction: const NextAction(
        label: 'Edit your bundle bid',
        kind: JobActionKind.submitBid,
      ),
      showBids: true,
      showMilestones: false,
      showAddress: false,
      showReviewPrompt: false,
      showCancel: false,
    );
  }

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
    headline = 'Review the job, then submit your bid.';
    action = NextAction(
      label: 'Submit a bid',
      kind: JobActionKind.submitBid,
      contextLine: job.budget?.label ?? job.location.address,
    );
  }

  return JobDetailViewModel(
    role: JobViewerRole.browser,
    statusHeadline: headline,
    primaryAction: action,
    showBids: true,
    showMilestones: false,
    showAddress: false,
    showReviewPrompt: false,
    showCancel: false,
  );
}

JobDetailViewModel _forOutsider(Job job) {
  return JobDetailViewModel(
    role: JobViewerRole.outsider,
    statusHeadline: job.status == JobStatus.cancelled
        ? 'This job was cancelled.'
        : 'This job is no longer open for bids.',
    showBids: false,
    showMilestones: false,
    showAddress: false,
    showReviewPrompt: false,
    showCancel: false,
  );
}
