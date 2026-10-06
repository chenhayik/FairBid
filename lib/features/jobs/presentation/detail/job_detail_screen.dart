import 'dart:async';
import 'dart:math' show min;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../../core/config/platform_config.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/money.dart';
import '../../../../core/util/motion.dart';
import '../../../../core/util/service_categories.dart';
import '../../../../core/util/time_ago.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/form_widgets.dart';
import '../../../../core/widgets/user_chip.dart';
import '../../../auth/domain/app_user.dart';
import '../../../auth/domain/user_role.dart';
import '../../../auth/presentation/auth_controller.dart';
import '../../../messages/data/chat_repository.dart';
import '../../../profile/data/public_profile_repository.dart';
import '../../../profile/data/review_repository.dart';
import '../../../profile/presentation/leave_review_sheet.dart';
import '../../data/bid_repository.dart';
import '../../data/bundle_bid_repository.dart';
import '../../data/bundle_repository.dart';
import '../../data/job_repository.dart';
import '../../data/milestone_repository.dart';
import '../../domain/bid.dart';
import '../../domain/bundle.dart';
import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';
import '../../domain/job_event.dart';
import '../../domain/milestone.dart';
import '../bid/open_bid_sheet.dart';
import '../bid/submit_bid_sheet.dart';
import '../widgets/bid_card.dart';
import '../widgets/insufficient_balance_dialog.dart';
import 'job_address_card.dart';
import 'job_detail_view_model.dart';
import 'job_video_player.dart';
import 'milestone_section.dart';
import 'photo_strip.dart';

/// Job detail screen. Sections keep a fixed order; only which ones show varies.
/// A pinned bottom bar holds the main action; rare ones go in the menu.
class JobDetailScreen extends StatefulWidget {
  const JobDetailScreen({
    super.key,
    required this.jobId,
    this.fromBundle = false,
  });

  final String jobId;

  /// Set when opened from the bundle screen, so "View bundle" goes back.
  final bool fromBundle;

  @override
  State<JobDetailScreen> createState() => _JobDetailScreenState();
}

class _JobDetailScreenState extends State<JobDetailScreen> {
  // Cached so rebuilds don't resubscribe to Firestore.
  late final Stream<Job?> _job = context.read<JobRepository>().watchJob(
    widget.jobId,
  );

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Job?>(
      stream: _job,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Scaffold(
            appBar: AppBar(title: const Text('Job details')),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        // A failed stream also emits null; don't mistake it for a removed job.
        // Ask the user to reopen, since a retry would not work.
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('Job details')),
            body: const SafeArea(
              child: EmptyState(
                icon: Icons.cloud_off,
                title: "Couldn't load this job",
                message:
                    'Check your connection, then go back and open the '
                    'job again.',
              ),
            ),
          );
        }
        final job = snapshot.data;
        if (job == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Job details')),
            body: const SafeArea(
              child: EmptyState(
                icon: Icons.search_off_rounded,
                title: 'Job not found',
                message: 'It may have been removed by the requestor.',
              ),
            ),
          );
        }
        return _JobDetailBody(job: job, fromBundle: widget.fromBundle);
      },
    );
  }
}

/// Whether [status] is a terminal escrow state - money has finished moving.
bool _isMilestoneTerminal(MilestoneStatus status) =>
    status == MilestoneStatus.released ||
    status == MilestoneStatus.resolved ||
    status == MilestoneStatus.refunded;

/// Opens (or creates) the job's chat thread. Used by the message tile
/// and by the bottom bar button.
Future<void> _openJobChat(BuildContext context, Job job) async {
  try {
    final id = await context.read<ChatRepository>().openConversation(job);
    if (!context.mounted) return;
    context.push('/messages/$id');
  } catch (_) {
    if (!context.mounted) return;
    // Clear old snackbars so the same error isn't shown twice.
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Could not open the chat. Please try again.'),
        ),
      );
  }
}

/// Withdraws the provider's own bid on [jobId], after confirmation.
Future<void> _withdrawBid(
  BuildContext context,
  String jobId,
  String uid,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Withdraw your bid?'),
      content: const Text(
        'Your bid will be removed from this job. You can bid again while '
        'the job is still open.',
      ),
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
    await context.read<BidRepository>().withdrawBid(jobId, uid);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Bid withdrawn.')));
  } on BidNotPendingException {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('This bid was just accepted or resolved.')),
    );
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not withdraw the bid. Please try again.'),
      ),
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
  'dispute_withdrawn' => Icons.handshake_outlined,
  'completed' => Icons.check_circle_outline,
  'cancelled' => Icons.cancel_outlined,
  'price_changed' => Icons.price_change_outlined,
  _ => Icons.circle,
};

/// Colour for a timeline entry, keyed by [JobEvent.type].
Color _timelineColor(BuildContext context, String type) => switch (type) {
  'cancelled' || 'disputed' => context.fairbid.danger,
  'refunded' => context.fairbid.warningText,
  'released' || 'completed' => context.fairbid.successText,
  _ => context.fairbid.verified,
};

/// Wraps [child] with [key] so a bottom-bar button can scroll to it.
Widget _keyed(GlobalKey key, Widget child) =>
    KeyedSubtree(key: key, child: child);

/// The loaded job body: scroll content plus the pinned bottom bar.
class _JobDetailBody extends StatefulWidget {
  const _JobDetailBody({required this.job, required this.fromBundle});
  final Job job;
  final bool fromBundle;

  @override
  State<_JobDetailBody> createState() => _JobDetailBodyState();
}

class _JobDetailBodyState extends State<_JobDetailBody> {
  final _bidsSectionKey = GlobalKey();
  final _bidListKey = GlobalKey<_BidsOrBidActionState>();

  // Typed so the bottom bar can trigger actions in those sections.
  final _milestonesKey = GlobalKey<MilestoneSectionState>();
  final _reviewKey = GlobalKey<_LeaveReviewCardState>();

  /// True while a milestone action runs; drives the bottom bar's busy state.
  final _actionBusy = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _actionBusy.dispose();
    super.dispose();
  }

  late final String? _myUid = context.read<AuthController>().user?.uid;

  /// Only a provider viewing an open job that isn't theirs needs a bid
  /// stream. Status only moves forward, so deciding once is enough.
  late final bool _tracksMyBid =
      _myUid != null && widget.job.status == JobStatus.open;

  late final Stream<Bid?>? _myBid = _tracksMyBid
      ? context.read<BidRepository>().watchMyBid(widget.job.id, _myUid!)
      : null;

  /// Only a provider on an open bundle task needs the package-bid stream.
  /// Such a task has no per-job bid of its own.
  late final bool _tracksMyBundleBid =
      _myUid != null &&
      widget.job.isLiveBundleTask &&
      context.read<AuthController>().user?.role == UserRole.provider;

  late final Stream<BundleBid?>? _myBundleBid = _tracksMyBundleBid
      ? context.read<BundleBidRepository>().watchMyBundleBid(
          widget.job.bundleId!,
          _myUid!,
        )
      : null;

  /// Feeds the bottom bar's fund/release/deliver actions. Created on first
  /// need, since a provider and milestones can appear while this is open.
  Stream<List<Milestone>>? _milestoneStream;
  Stream<List<Milestone>>? get _milestones {
    if (widget.job.acceptedProviderId == null) return null;
    return _milestoneStream ??= context
        .read<MilestoneRepository>()
        .watchMilestones(widget.job.id);
  }

  void _scrollTo(GlobalKey key) {
    final target = key.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: motion(context, const Duration(milliseconds: 300)),
      curve: Curves.easeInOut,
    );
  }

  void _handleAction(
    BuildContext context,
    Job job,
    AppUser? me,
    JobActionKind kind,
    Bid? myBid,
  ) {
    switch (kind) {
      case JobActionKind.compareBids:
        final bids = _bidListKey.currentState;
        if (bids != null && bids.canCompare) {
          bids.openCompare();
        } else {
          _scrollTo(_bidsSectionKey);
        }
      case JobActionKind.editBid:
        if (me != null) {
          SubmitBidSheet.show(context, job: job, bidder: me, existing: myBid);
        }
      case JobActionKind.releaseMilestone:
      case JobActionKind.markDelivered:
        _milestonesKey.currentState?.runCurrentAction();
      case JobActionKind.message:
        _openJobChat(context, job);
      case JobActionKind.leaveReview:
        // Opens the sheet when a review is due, else shows why not.
        final card = _reviewKey.currentState;
        if (card != null && card.canReview) {
          card.open();
        } else {
          _scrollTo(_reviewKey);
        }
      case JobActionKind.submitBid:
        if (me != null) openBidSheet(context, job, me);
      case JobActionKind.getVerified:
        context.push('/onboarding');
      case JobActionKind.viewBundle:
        _viewBundle(context, job);
    }
  }

  /// Opens [job]'s bundle, or goes back if we came from that bundle.
  void _viewBundle(BuildContext context, Job job) {
    if (widget.fromBundle && context.canPop()) {
      context.pop();
    } else {
      context.push('/bundles/${job.bundleId}?fromTask=${job.id}');
    }
  }

  /// Cancels [job]. A task in an open bundle cancels the whole bundle;
  /// other jobs use [JobRepository.cancelOpenJob].
  Future<void> _cancelJob(BuildContext context, Job job) async {
    final isBundleTask = job.isLiveBundleTask;
    final taskCount = job.bundleTaskCount;
    final bundleBody = taskCount != null
        ? 'All $taskCount tasks in this bundle will be cancelled and '
              'providers will no longer be able to bid. This cannot be undone.'
        : 'Every task in this bundle will be cancelled and providers will '
              'no longer be able to bid. This cannot be undone.';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isBundleTask ? 'Cancel this bundle?' : 'Cancel this job?'),
        content: Text(
          isBundleTask
              ? bundleBody
              : 'Your job posting will be closed and providers will no '
                    'longer be able to bid. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(isBundleTask ? 'Keep bundle' : 'Keep job'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.fairbid.danger,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(isBundleTask ? 'Cancel bundle' : 'Cancel job'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      if (isBundleTask) {
        await context.read<BundleRepository>().cancelBundle(job.bundleId!);
      } else {
        await context.read<JobRepository>().cancelOpenJob(job.id);
      }
    } on BundleRejectedException catch (e) {
      // Written by the server for requestors, so shown as-is.
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isBundleTask
                ? 'Could not cancel the bundle. Please try again.'
                : 'Could not cancel the job. Please try again.',
          ),
        ),
      );
    }
  }

  Future<void> _requestCancellation(BuildContext context, Job job) async {
    final reason = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Request cancellation?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'The other party must agree before the job is cancelled. '
              'Money in escrow for work not yet delivered is refunded to the '
              'client. A delivered or disputed milestone must be released or '
              'resolved first.',
            ),
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
    if (confirmed != true || !context.mounted) return;
    try {
      await context.read<JobRepository>().requestCancellation(
        job.id,
        reason: text.isEmpty ? null : text,
      );
    } on FirebaseFunctionsException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message ?? 'Something went wrong. Please try again.'),
        ),
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Something went wrong. Please try again.'),
        ),
      );
    }
  }

  /// Dialog to propose a new agreed price; sends it on confirm.
  Future<void> _requestPriceChange(BuildContext context, Job job) async {
    final current = job.acceptedBidAmountSen ?? 0;
    final original = job.originalBidAmountSen;
    final amount = TextEditingController(
      text: (current / 100).toStringAsFixed(2),
    );
    final reason = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Request price change'),
        content: SingleChildScrollView(
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Current price: ${formatRm(current)}'),
                if (original != null && original != current)
                  Text('Original: ${formatRm(original)}'),
                const SizedBox(height: 12),
                AppTextField(
                  controller: amount,
                  label: 'New price (RM)',
                  prefixText: 'RM ',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: (v) {
                    final sen = parseRmToSen(v);
                    if (sen == null) return 'Enter the new price.';
                    if (sen <= 0) return 'Amount must be more than RM 0.';
                    if (sen == current) return 'That is the current price.';
                    return null;
                  },
                ),
                AppTextField(
                  controller: reason,
                  label: 'Reason',
                  maxLines: 3,
                  maxLength: 500,
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Explain why the price should change.'
                      : null,
                ),
                Text(
                  'The other party must agree. An increase moves the extra '
                  'into escrow; a decrease is refunded to the client from '
                  'work not yet delivered.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.of(context).pop(true);
              }
            },
            child: const Text('Send request'),
          ),
        ],
      ),
    );
    final newSen = parseRmToSen(amount.text);
    final text = reason.text.trim();
    amount.dispose();
    reason.dispose();
    if (confirmed != true || newSen == null || !context.mounted) return;
    await _runPriceChangeCall(
      context,
      () => context.read<JobRepository>().requestPriceChange(
        job.id,
        newAmountSen: newSen,
        reason: text,
      ),
    );
  }

  /// Why the price can't be changed now, or null when it can.
  String? _priceChangeBlocker(Job job) {
    if (job.isBundleTask) return 'Not available for bundle tasks.';
    if (_milestonesKey.currentState?.hasOpenDispute == true) {
      return 'Wait until the dispute is decided.';
    }
    if (job.hasPendingPriceChange) {
      return 'A price change is already waiting for an answer.';
    }
    if (job.hasPendingCancellation) return 'Answer the cancellation first.';
    if (job.priceChangeCount >= 3) {
      return 'The price has already been changed 3 times.';
    }
    return null;
  }

  /// Whether the "Problem with this job?" button applies to this viewer.
  bool _showProblemButton(Job job, JobDetailViewModel vm) {
    final isParty = vm.role == JobViewerRole.owner ||
        vm.role == JobViewerRole.acceptedProvider;
    return isParty &&
        (job.status == JobStatus.inProgress ||
            (job.status == JobStatus.open && vm.showCancel));
  }

  /// One place for every way out of a job, each saying why if it's blocked.
  Future<void> _openProblemSheet(
    BuildContext context,
    Job job,
    JobDetailViewModel vm,
  ) async {
    final inProgress = job.status == JobStatus.inProgress;
    final milestones = _milestonesKey.currentState;
    final options = <(String, IconData, String?, VoidCallback)>[
      if (inProgress)
        (
          'Change the price',
          Icons.price_change_outlined,
          _priceChangeBlocker(job),
          () => _requestPriceChange(context, job),
        ),
      if (inProgress)
        (
          'Raise a dispute',
          Icons.gavel_rounded,
          milestones?.hasOpenDispute == true
              ? 'A dispute is already open.'
              : milestones?.disputableMilestone == null
              ? 'Only once payment is held in escrow.'
              : null,
          () => milestones?.raiseDispute(),
        ),
      if (job.status == JobStatus.open)
        ('Cancel job', Icons.cancel_outlined, null,
            () => _cancelJob(context, job))
      else
        (
          'Ask to cancel the job',
          Icons.cancel_outlined,
          !vm.showCancel
              ? 'Not available for this job.'
              : job.hasPendingCancellation
              ? 'A cancellation request is already open.'
              : job.hasPendingPriceChange
              ? 'Answer the price change first.'
              : null,
          () => _requestCancellation(context, job),
        ),
    ];
    final picked = await showModalBottomSheet<VoidCallback>(
      context: context,
      useSafeArea: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Problem with this job?',
                  style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'If you can, talk to the other person in chat first.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              for (final (label, icon, blocker, action) in options)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  enabled: blocker == null,
                  leading: Icon(icon),
                  title: Text(label),
                  subtitle: blocker == null ? null : Text(blocker),
                  onTap: () => Navigator.of(context).pop(action),
                ),
            ],
          ),
        );
      },
    );
    if (!context.mounted) return;
    picked?.call();
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final me = context.watch<AuthController>().user;
    final bundleBidStream = _myBundleBid;

    Widget withMyBundleBid(Bid? myBid) {
      if (bundleBidStream == null) {
        return _scaffold(context, job, me, myBid, null);
      }
      return StreamBuilder<BundleBid?>(
        stream: bundleBidStream,
        builder: (context, snapshot) =>
            _scaffold(context, job, me, myBid, snapshot.data),
      );
    }

    final bidStream = _myBid;
    if (bidStream == null) {
      return withMyBundleBid(null);
    }
    return StreamBuilder<Bid?>(
      stream: bidStream,
      builder: (context, snapshot) => withMyBundleBid(snapshot.data),
    );
  }

  Widget _scaffold(
    BuildContext context,
    Job job,
    AppUser? me,
    Bid? myBid,
    BundleBid? myBundleBid,
  ) {
    final vm = buildJobDetailVm(job, me, myBid, myBundleBid: myBundleBid);
    final milestones = _milestones;
    // In progress, milestone data changes the bottom bar action and the
    // sections shown (e.g. skip a message tile the bar already offers).
    if (milestones == null || !_milestoneAware(vm, job)) {
      return _scaffoldWithBar(
        context,
        job,
        me,
        myBid,
        myBundleBid,
        vm,
        _ResolvedBar(action: vm.primaryAction, waitingLine: vm.waitingLine),
      );
    }
    return StreamBuilder<List<Milestone>>(
      stream: milestones,
      builder: (context, snapshot) => _scaffoldWithBar(
        context,
        job,
        me,
        myBid,
        myBundleBid,
        vm,
        _resolveMilestoneBar(vm, snapshot.data),
      ),
    );
  }

  Widget _scaffoldWithBar(
    BuildContext context,
    Job job,
    AppUser? me,
    Bid? myBid,
    BundleBid? myBundleBid,
    JobDetailViewModel vm,
    _ResolvedBar bar,
  ) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            title: const Text('Job details'),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            // Built eagerly so the bottom bar can reach them
            // through their GlobalKeys.
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _slots(context, job, me, myBid, myBundleBid, vm, bar),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _Bar(
        action: bar.action,
        waitingLine: bar.waitingLine,
        busy: _actionBusy,
        onAction: (kind) => _handleAction(context, job, me, kind, myBid),
      ),
    );
  }

  List<Widget> _slots(
    BuildContext context,
    Job job,
    AppUser? me,
    Bid? myBid,
    BundleBid? myBundleBid,
    JobDetailViewModel vm,
    _ResolvedBar bar,
  ) {
    final isOwner = vm.role == JobViewerRole.owner;
    void viewBundle() => _viewBundle(context, job);
    final showCounterparty = isOwner ? job.acceptedProviderId != null : true;

    final slots = <Widget>[];
    void add(Widget? widget) {
      if (widget == null) return;
      if (slots.isNotEmpty) slots.add(const SizedBox(height: 16));
      slots.add(widget);
    }

    add(_StatusHeadline(vm: vm));
    add(
      vm.showCancellationResponse
          ? _CancellationResponseCard(job: job, role: vm.role)
          : null,
    );
    add(
      vm.showPriceChangeCard ? _PriceChangeCard(job: job, role: vm.role) : null,
    );
    // A never-awarded bundle task (e.g. bundle cancelled) shows nothing here;
    // the owner's "View bundle" is in the bar, a provider's in the banner.
    add(
      job.isBiddingAsBundle
          ? _BundleTaskBanner(
              job: job,
              onViewBundle: isOwner ? null : viewBundle,
            )
          : job.isLiveBundleTask &&
                (job.status == JobStatus.inProgress ||
                    job.status == JobStatus.completed) &&
                job.acceptedProviderId != null
          ? _AwardedBundleTaskBanner(
              job: job,
              onViewBundle: isOwner ? viewBundle : null,
            )
          : job.isBundleTask && !job.isLiveBundleTask
          ? _ReleasedBundleTaskBanner(onViewBundle: isOwner ? viewBundle : null)
          : null,
    );
    add(_HeroFacts(job: job));
    add(
      licenceNoticeFor(job.category) != null
          ? InfoBanner(
              icon: Icons.verified_user_outlined,
              title: 'Licensing',
              body: licenceNoticeFor(job.category)!,
            )
          : null,
    );
    add(
      showCounterparty
          ? _CounterpartyCard(job: job, isOwnerView: isOwner)
          : null,
    );
    add(_DescriptionAndMedia(job: job));
    add(
      vm.showBids
          ? _keyed(
              _bidsSectionKey,
              _BidsOrBidAction(
                key: _bidListKey,
                job: job,
                isOwner: isOwner,
                me: me,
                myBid: myBid,
              ),
            )
          : null,
    );
    // showBids is false here: a bundle task has no own bid, so we'd wrongly
    // show "Submit a bid" to a provider whose package bid covers it.
    add(
      vm.role == JobViewerRole.browser &&
              me != null &&
              job.isLiveBundleTask &&
              myBundleBid != null &&
              myBundleBid.status == BundleBidStatus.pending &&
              myBundleBid.coversTask(job.id)
          ? _keyed(
              _bidsSectionKey,
              _YourBundleBidCard(job: job, bid: myBundleBid),
            )
          : null,
    );
    add(
      vm.showMilestones
          ? MilestoneSection(key: _milestonesKey, job: job, busy: _actionBusy)
          : null,
    );
    add(
      vm.showAddress
          ? _WorkingDetails(
              job: job,
              isOwner: isOwner,
              // The bar may already be offering to message.
              showMessage: bar.action?.kind != JobActionKind.message,
            )
          : null,
    );
    add(
      vm.showReviewPrompt
          ? _LeaveReviewCard(
              key: _reviewKey,
              job: job,
              revieweeId: isOwner ? job.acceptedProviderId! : job.requestorId,
              revieweeName: isOwner
                  ? job.acceptedProviderName ?? 'Provider'
                  : job.requestorName,
            )
          : null,
    );
    add(
      _showProblemButton(job, vm)
          ? OutlinedButton.icon(
              onPressed: () => _openProblemSheet(context, job, vm),
              icon: const Icon(Icons.help_outline),
              label: const Text('Problem with this job?'),
            )
          : null,
    );
    // An open job has only its lone "posted" event - not worth a card.
    add(job.status != JobStatus.open ? _ActivityTimeline(job: job) : null);

    return slots;
  }
}

/// One plain sentence saying whose turn it is.
class _StatusHeadline extends StatelessWidget {
  const _StatusHeadline({required this.vm});
  final JobDetailViewModel vm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 18, color: context.fairbid.verified),
        const SizedBox(width: 8),
        Expanded(
          child: Text(vm.statusHeadline, style: theme.textTheme.titleMedium),
        ),
      ],
    );
  }
}

/// Explains how a bundle task bids and cancels differently.
class _BundleTaskBanner extends StatelessWidget {
  const _BundleTaskBanner({required this.job, this.onViewBundle});
  final Job job;

  /// Adds a "View bundle" button; null for the owner, whose bottom bar
  /// already has it.
  final VoidCallback? onViewBundle;

  @override
  Widget build(BuildContext context) {
    final count = job.bundleTaskCount;
    return InfoBanner(
      icon: Icons.inventory_2_outlined,
      bottom: onViewBundle == null
          ? null
          : TextButton(
              onPressed: onViewBundle,
              child: const Text('View bundle'),
            ),
      title: 'Part of a bundle',
      body: count != null && count > 1
          ? 'This is one of $count tasks in a bundle. Providers bid on the '
                'tasks they pick as one package, and awarding or cancelling '
                'happens for the whole bundle at once.'
          : 'This task is bid on together with the rest of its bundle, as '
                'one package.',
    );
  }
}

/// Banner for an awarded bundle task: names the bundle it was awarded in.
/// Replaces [_BundleTaskBanner] while the task is live.
class _AwardedBundleTaskBanner extends StatefulWidget {
  const _AwardedBundleTaskBanner({required this.job, this.onViewBundle});
  final Job job;
  final VoidCallback? onViewBundle;

  @override
  State<_AwardedBundleTaskBanner> createState() =>
      _AwardedBundleTaskBannerState();
}

class _AwardedBundleTaskBannerState extends State<_AwardedBundleTaskBanner> {
  late final Future<Bundle?> _bundle = context.read<BundleRepository>().getById(
    widget.job.bundleId!,
  );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Bundle?>(
      future: _bundle,
      builder: (context, snapshot) {
        final title = snapshot.data?.title;
        return InfoBanner(
          icon: Icons.inventory_2_outlined,
          bottom: widget.onViewBundle == null
              ? null
              : TextButton(
                  onPressed: widget.onViewBundle,
                  child: const Text('View bundle'),
                ),
          title: 'Part of a bundle',
          body:
              'Awarded as part of '
              '${title != null && title.isNotEmpty ? '"$title"' : 'a bundle'}.',
        );
      },
    );
  }
}

/// Banner for a task the bundle left unawarded; it now takes normal bids.
/// Replaces [_BundleTaskBanner] once `job.releasedAt` is set.
class _ReleasedBundleTaskBanner extends StatelessWidget {
  const _ReleasedBundleTaskBanner({this.onViewBundle});
  final VoidCallback? onViewBundle;

  @override
  Widget build(BuildContext context) {
    return InfoBanner(
      icon: Icons.inventory_2_outlined,
      // The owner can still see the bundle it came from.
      bottom: onViewBundle == null
          ? null
          : TextButton(
              onPressed: onViewBundle,
              child: const Text('View bundle'),
            ),
      title: 'Released from its bundle',
      body:
          "This task wasn't awarded with the rest of its bundle, so it "
          'now takes ordinary bids.',
    );
  }
}

/// A cancellation request waiting for this viewer's answer.
/// Kept high up because it needs attention.
class _CancellationResponseCard extends StatefulWidget {
  const _CancellationResponseCard({required this.job, required this.role});
  final Job job;
  final JobViewerRole role;

  @override
  State<_CancellationResponseCard> createState() =>
      _CancellationResponseCardState();
}

class _CancellationResponseCardState extends State<_CancellationResponseCard> {
  bool _busy = false;

  Future<void> _respond(bool accept) async {
    setState(() => _busy = true);
    try {
      await context.read<JobRepository>().respondToCancellation(
        widget.job.id,
        accept: accept,
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message ?? 'Something went wrong. Please try again.'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Something went wrong. Please try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final job = widget.job;
    final myRole = widget.role == JobViewerRole.owner
        ? 'requestor'
        : 'provider';
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
            Text(
              '"$reason"',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (iRequested)
            Text(
              'Waiting for the other party to respond.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else ...[
            PrimaryButton(
              label: 'Accept & cancel job',
              busy: _busy,
              onPressed: () => _respond(true),
            ),
            const SizedBox(height: 8),
            SecondaryButton(
              label: 'Decline',
              onPressed: _busy ? null : () => _respond(false),
            ),
          ],
        ],
      ),
    );
  }
}

/// Runs a price-change call and shows failures in a SnackBar. Low balance
/// for the requestor reuses the top-up dialog.
Future<void> _runPriceChangeCall(
  BuildContext context,
  Future<void> Function() call, {
  bool isRequestor = true,
}) async {
  String? message;
  try {
    await call();
    return;
  } on InsufficientBalanceException catch (e) {
    if (!context.mounted) return;
    if (isRequestor) {
      await showInsufficientBalanceDialog(context, e);
      return;
    }
    message =
        'The client needs ${formatRm(e.shortfallSen)} more available '
        'balance to fund this increase.';
  } on FirebaseFunctionsException catch (e) {
    message = e.message;
  } catch (_) {
    message = null;
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message ?? 'Something went wrong. Please try again.'),
    ),
  );
}

/// A pending price change: the responder accepts or declines;
/// the proposer waits or withdraws.
class _PriceChangeCard extends StatefulWidget {
  const _PriceChangeCard({required this.job, required this.role});
  final Job job;
  final JobViewerRole role;

  @override
  State<_PriceChangeCard> createState() => _PriceChangeCardState();
}

class _PriceChangeCardState extends State<_PriceChangeCard> {
  bool _busy = false;

  Future<void> _run(Future<void> Function(JobRepository repo) call) async {
    setState(() => _busy = true);
    final repo = context.read<JobRepository>();
    await _runPriceChangeCall(
      context,
      () => call(repo),
      isRequestor: widget.role == JobViewerRole.owner,
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final job = widget.job;
    final request = job.priceChangeRequest!;
    final myRole = widget.role == JobViewerRole.owner
        ? 'requestor'
        : 'provider';
    final iRequested = request.by == myRole;
    final subdued = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            iRequested
                ? 'Price change requested'
                : request.by == 'requestor'
                ? 'The client wants to change the price'
                : 'The provider wants to change the price',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            '${formatRm(job.acceptedBidAmountSen ?? 0)} → '
            '${formatRm(request.newAmountSen)}',
            style: theme.textTheme.titleSmall,
          ),
          if (request.reason.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('"${request.reason}"', style: subdued),
          ],
          const SizedBox(height: 12),
          if (iRequested) ...[
            Text('Waiting for the other party', style: subdued),
            const SizedBox(height: 8),
            SecondaryButton(
              label: 'Withdraw',
              onPressed: _busy
                  ? null
                  : () => _run((repo) => repo.withdrawPriceChange(job.id)),
            ),
          ] else ...[
            PrimaryButton(
              label: 'Accept',
              busy: _busy,
              onPressed: () => _run(
                (repo) => repo.respondToPriceChange(job.id, accept: true),
              ),
            ),
            const SizedBox(height: 8),
            SecondaryButton(
              label: 'Decline',
              onPressed: _busy
                  ? null
                  : () => _run(
                      (repo) =>
                          repo.respondToPriceChange(job.id, accept: false),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Hero facts: category, status, budget, location and deadline as tiles.
class _HeroFacts extends StatelessWidget {
  const _HeroFacts({required this.job});
  final Job job;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(job.title, style: theme.textTheme.headlineMedium),
        const SizedBox(height: 4),
        Row(
          children: [
            Icon(
              Icons.schedule,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Text(
              'Posted ${timeAgo(job.createdAt)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _FactTile(
              icon: Icons.category_outlined,
              label: 'Category',
              value: job.category,
            ),
            _FactTile(
              icon: Icons.flag_outlined,
              label: 'Status',
              value: job.status.label,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            if (job.budget?.label != null)
              _FactTile(
                icon: Icons.payments_outlined,
                label: 'Likely price',
                value: job.budget!.label!,
              ),
            _FactTile(
              icon: Icons.location_on_outlined,
              label: 'Location',
              value: job.location.address,
            ),
            // Only while bidding is live; afterwards it would be stale
            // (e.g. "closes in 4 days" on a job already in progress).
            if (job.deadline != null && job.status == JobStatus.open)
              _FactTile(
                icon: Icons.timer_outlined,
                label: 'Bidding',
                value: deadlineLabel(job.deadline),
              ),
          ],
        ),
      ],
    );
  }
}

class _FactTile extends StatelessWidget {
  const _FactTile({
    required this.icon,
    required this.label,
    required this.value,
    this.color,
  });
  final IconData icon;
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = color ?? context.fairbid.verified;
    return Container(
      constraints: const BoxConstraints(minWidth: 128),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: context.fairbid.subtleBlue,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: accent),
              const SizedBox(width: 4),
              Text(
                label.toUpperCase(),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// The other party: the poster (for providers) or the provider (for the
/// owner). Taps through to `/users/:uid`.
class _CounterpartyCard extends StatelessWidget {
  const _CounterpartyCard({required this.job, required this.isOwnerView});
  final Job job;
  final bool isOwnerView;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final String label;
    final String uid;
    final String name;
    final String? photoUrl;
    final String? subtitle;
    if (isOwnerView) {
      label = 'Assigned provider';
      uid = job.acceptedProviderId!;
      name = job.acceptedProviderName ?? 'Provider';
      photoUrl = null;
      subtitle = job.acceptedBidAmountSen != null
          ? (job.originalBidAmountSen != null &&
                    job.originalBidAmountSen != job.acceptedBidAmountSen
                ? 'Agreed price: ${formatRm(job.acceptedBidAmountSen!)} '
                      '(was ${formatRm(job.originalBidAmountSen!)})'
                : 'Accepted bid: ${formatRm(job.acceptedBidAmountSen!)}')
          : null;
    } else {
      label = 'Client';
      uid = job.requestorId;
      name = job.requestorName;
      photoUrl = job.requestorPhotoUrl;
      subtitle = null;
    }
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelMedium),
          const SizedBox(height: 8),
          UserChip(
            uid: uid,
            name: name,
            photoUrl: photoUrl,
            subtitle: subtitle,
            nameStyle: theme.textTheme.titleLarge,
          ),
        ],
      ),
    );
  }
}

/// Description, then photos, then video.
class _DescriptionAndMedia extends StatelessWidget {
  const _DescriptionAndMedia({required this.job});
  final Job job;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Description', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        _JobDescription(text: job.description),
        if (job.photoUrls.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Photos', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          PhotoStrip(photoUrls: job.photoUrls),
        ],
        if (job.videoUrl != null) ...[
          const SizedBox(height: 16),
          Text('Video', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          JobVideoPreview(url: job.videoUrl!),
        ],
      ],
    );
  }
}

/// The description, bolding the section labels the AI helper writes.
/// Other descriptions render unchanged.
class _JobDescription extends StatelessWidget {
  const _JobDescription({required this.text});
  final String text;

  static const _labels = {
    'What needs doing',
    'Access & details',
    'Expected outcome',
  };

  @override
  Widget build(BuildContext context) {
    final lines = text.split('\n');
    return Text.rich(
      TextSpan(
        children: [
          for (final (i, line) in lines.indexed) ...[
            TextSpan(
              text: line,
              style: _labels.contains(line)
                  ? const TextStyle(fontWeight: FontWeight.bold)
                  : null,
            ),
            if (i != lines.length - 1) const TextSpan(text: '\n'),
          ],
        ],
      ),
      style: Theme.of(context).textTheme.bodyLarge,
    );
  }
}

/// Bid sort order. `bestValue` blends price and Trust Score.
enum _BidSort { bestValue, price }

/// Best Value score for [bid]: cheaper and more trusted scores higher.
/// A "New" provider counts as the neutral baseline, not their hidden score.
double _compositeScore(Bid bid, int lowestSen) {
  final priceScore = lowestSen / bid.amountSen;
  final trust = (bid.providerScoreVisible
          ? bid.providerTrustScore
          : PlatformConfig.neutralTrustScore) /
      1000;
  return PlatformConfig.priceWeight * priceScore +
      PlatformConfig.trustWeight * trust;
}

/// The owner's bid list (sort, Accept) while open, or the provider's own
/// bid action.
class _BidsOrBidAction extends StatefulWidget {
  const _BidsOrBidAction({
    super.key,
    required this.job,
    required this.isOwner,
    required this.me,
    required this.myBid,
  });
  final Job job;
  final bool isOwner;
  final AppUser? me;

  /// The provider's own live bid on [job], passed down so this widget
  /// doesn't open a second `watchMyBid` stream.
  final Bid? myBid;

  @override
  State<_BidsOrBidAction> createState() => _BidsOrBidActionState();
}

class _BidsOrBidActionState extends State<_BidsOrBidAction> {
  _BidSort _sort = _BidSort.bestValue;

  /// Provider id of the bid being accepted, or null. Accepting takes a
  /// moment, so this shows progress and stops double taps.
  String? _acceptingProviderId;

  /// Live trust scores of bidders, by uid. Bid snapshots go stale, so
  /// these are fetched once per set of bidders and cached.
  Map<String, ProviderTrust> _liveTrust = const {};
  String? _trustFetchedFor;

  /// Fetches live trust for [bids] unless already resolved.
  /// Safe to call from build.
  void _resolveTrust(List<Bid> bids) {
    final key = (bids.map((b) => b.providerId).toList()..sort()).join(',');
    if (key.isEmpty || key == _trustFetchedFor) return;
    _trustFetchedFor = key;
    context
        .read<PublicProfileRepository>()
        .fetchTrust(bids.map((b) => b.providerId))
        .then((trust) {
          if (mounted) setState(() => _liveTrust = trust);
        })
        .catchError((_) {
          // Fall back to the stored snapshot; never blank the bid list.
        });
  }

  /// The bids as last shown, for the bottom bar's "Compare" sheet.
  List<Bid> _shownBids = const [];
  String? _bestValueId;

  bool get canCompare => _shownBids.length > 1 && _acceptingProviderId == null;

  /// Side-by-side view of every pending bid; picking one starts its accept.
  Future<void> openCompare() async {
    final picked = await showModalBottomSheet<Bid>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) =>
          _CompareBidsSheet(bids: _shownBids, bestValueId: _bestValueId),
    );
    if (picked != null && mounted) await _accept(picked);
  }

  // Cached so changing sort reorders locally without resubscribing.
  late final Stream<List<Bid>> _bids = context.read<BidRepository>().watchBids(
    widget.job.id,
  );

  Future<void> _accept(Bid bid) async {
    final available = context.read<AuthController>().user?.availableBalanceSen;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Accept this bid?'),
        content: Text(
          '${bid.providerName} will be assigned to "${widget.job.title}" '
          'for ${formatRm(bid.amountSen)}. Other bids will be declined.'
          '\n\nThe ${formatRm(bid.amountSen)} moves into escrow now and is '
          'paid to them when you release it after the work is done.'
          '${available != null ? '\n\nYour available balance: '
                    '${formatRm(available)}.' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Accept bid'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Capture the outcome and clear the busy state before reporting it,
    // so the button doesn't spin behind the error dialog.
    Object? failure;
    setState(() => _acceptingProviderId = bid.providerId);
    try {
      await context.read<BidRepository>().acceptBid(bid);
    } catch (error) {
      failure = error;
    }
    if (!mounted) return;
    setState(() => _acceptingProviderId = null);

    if (failure == null) {
      // Haptic confirm for a big commitment. Not awaited so a haptic
      // failure can't fail the accept.
      unawaited(HapticFeedback.mediumImpact());
      return;
    }

    if (failure is InsufficientBalanceException) {
      await showInsufficientBalanceDialog(context, failure);
    } else if (failure is BidAcceptRaceException) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This job changed: please review the current bids '
            'and try again.',
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not accept the bid. Please try again.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isOwner) return _buildOwnerBidList(context);

    final user = widget.me;
    if (user == null || user.verificationStatus != 'approved') {
      return const InfoBanner(
        icon: Icons.lock_outline,
        title: 'Bidding locked',
        body:
            'Bidding unlocks once an admin approves your verification '
            'documents.',
      );
    }
    return _BidAction(job: widget.job, user: user, myBid: widget.myBid);
  }

  Widget _buildOwnerBidList(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<List<Bid>>(
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
        final rawBids = (snapshot.data ?? [])
            .where((b) => b.status == BidStatus.pending)
            .toList();

        // Start (or skip) the live trust lookup and use what's resolved.
        // Until then the bid's own snapshot is used, so the list shows now.
        _resolveTrust(rawBids);
        final bids = [
          for (final bid in rawBids)
            if (_liveTrust[bid.providerId] case final t?)
              bid.withTrust(
                trustScore: t.trustScore,
                scoreVisible: t.scoreVisible,
              )
            else
              bid,
        ];

        _shownBids = bids;
        if (bids.isEmpty) {
          return const AppCard(
            child: EmptyState(
              icon: Icons.gavel_rounded,
              title: 'No bids yet',
              message:
                  'Providers\' bids will appear here as they come in. '
                  'You\'ll compare and accept one.',
            ),
          );
        }

        // The composite needs the cheapest bid; compute once and share it.
        final lowestSen = bids.map((b) => b.amountSen).reduce(min);
        bids.sort(switch (_sort) {
          _BidSort.price => (a, b) => a.amountSen.compareTo(b.amountSen),
          _BidSort.bestValue => (a, b) => _compositeScore(
            b,
            lowestSen,
          ).compareTo(_compositeScore(a, lowestSen)),
        });
        // The single Best Value bid, badged regardless of the current sort.
        final bestValueId = bids
            .reduce(
              (a, b) =>
                  _compositeScore(a, lowestSen) >= _compositeScore(b, lowestSen)
                  ? a
                  : b,
            )
            .providerId;
        _bestValueId = bestValueId;

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
                  ButtonSegment(value: _BidSort.bestValue, label: Text('Best')),
                  ButtonSegment(value: _BidSort.price, label: Text('Price')),
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
                  busy: _acceptingProviderId == bid.providerId,
                  enabled: _acceptingProviderId == null,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// A table of all pending bids, marking the cheapest, most trusted and
/// Best Value. Tapping a row starts its accept.
class _CompareBidsSheet extends StatelessWidget {
  const _CompareBidsSheet({required this.bids, this.bestValueId});
  final List<Bid> bids;
  final String? bestValueId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lowest = bids.map((b) => b.amountSen).reduce(min);
    final topTrust = bids
        .where((b) => b.providerScoreVisible)
        .map((b) => b.providerTrustScore)
        .fold<int>(-1, (a, b) => a > b ? a : b);
    final highlight = TextStyle(
      color: context.fairbid.successText,
      fontWeight: FontWeight.w700,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Compare ${bids.length} bids',
            style: theme.textTheme.headlineMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Green marks the lowest price and highest Trust Score. Tap a '
            'row to accept that bid.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              showCheckboxColumn: false,
              columnSpacing: 20,
              horizontalMargin: 0,
              columns: const [
                DataColumn(label: Text('Provider')),
                DataColumn(label: Text('Price'), numeric: true),
                DataColumn(label: Text('Time')),
                DataColumn(label: Text('Trust')),
              ],
              rows: [
                for (final bid in bids)
                  DataRow(
                    onSelectChanged: (_) => Navigator.of(context).pop(bid),
                    cells: [
                      DataCell(
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (bid.providerId == bestValueId) ...[
                              Icon(
                                Icons.workspace_premium_outlined,
                                size: 18,
                                color: context.fairbid.successText,
                              ),
                              const SizedBox(width: 4),
                            ],
                            Text(bid.providerName),
                          ],
                        ),
                      ),
                      DataCell(
                        Text(
                          formatRm(bid.amountSen),
                          style: bid.amountSen == lowest ? highlight : null,
                        ),
                      ),
                      DataCell(Text(bid.estimatedDuration)),
                      DataCell(
                        Text(
                          bid.providerScoreVisible
                              ? '${(bid.providerTrustScore / 10).round()}/100'
                              : 'New',
                          style: bid.providerScoreVisible &&
                                  bid.providerTrustScore == topTrust
                              ? highlight
                              : null,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                Icons.workspace_premium_outlined,
                size: 16,
                color: context.fairbid.successText,
              ),
              const SizedBox(width: 6),
              Text('Best Value', style: theme.textTheme.bodySmall),
            ],
          ),
        ],
      ),
    );
  }
}

/// The provider's own bid card with Withdraw, or a "bidding closed" note.
/// [myBid] is resolved by the parent, so no second subscription opens.
class _BidAction extends StatelessWidget {
  const _BidAction({
    required this.job,
    required this.user,
    required this.myBid,
  });
  final Job job;
  final AppUser user;
  final Bid? myBid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bid = myBid;
    if (bid == null) {
      // The server may lag closing at the deadline, so check the deadline
      // directly instead of trusting job.status alone.
      if (job.deadline != null && job.deadline!.isBefore(DateTime.now())) {
        return const InfoBanner(
          icon: Icons.timer_off_outlined,
          title: 'Bidding closed',
          body: 'Bidding for this job has closed.',
        );
      }
      return const SizedBox.shrink();
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
                    child: Text(
                      formatRm(bid.amountSen),
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: context.fairbid.verified,
                      ),
                    ),
                  ),
                  Text(
                    bid.estimatedDuration,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SecondaryButton(
          label: 'Withdraw bid',
          onPressed: () => _withdrawBid(context, job.id, user.uid),
        ),
      ],
    );
  }
}

/// For a provider whose package bid covers this task: shows their quote
/// for it. Editing is the bottom bar's action.
class _YourBundleBidCard extends StatelessWidget {
  const _YourBundleBidCard({required this.job, required this.bid});
  final Job job;
  final BundleBid bid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final price = bid.priceFor(job.id)!;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Your bundle bid', style: theme.textTheme.labelMedium),
          const SizedBox(height: 4),
          Text(
            '${formatRm(price)} for this task (part of your bundle bid)',
            style: theme.textTheme.titleLarge?.copyWith(
              color: context.fairbid.verified,
            ),
          ),
        ],
      ),
    );
  }
}

/// The private service-address card, plus the chat entry (unless
/// [showMessage] is false because the bottom bar offers it).
class _WorkingDetails extends StatelessWidget {
  const _WorkingDetails({
    required this.job,
    required this.isOwner,
    required this.showMessage,
  });
  final Job job;
  final bool isOwner;
  final bool showMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final counterpartyName = isOwner
        ? (job.acceptedProviderName ?? 'provider')
        : job.requestorName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        JobAddressCard(job: job, isOwner: isOwner),
        if (showMessage) ...[
          const SizedBox(height: 16),
          AppCard(
            child: InkWell(
              onTap: () => _openJobChat(context, job),
              borderRadius: BorderRadius.circular(8),
              child: Row(
                children: [
                  Icon(
                    Icons.chat_bubble_outline,
                    color: context.fairbid.verified,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Message $counterpartyName',
                      style: theme.textTheme.bodyLarge,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Review status of a completed job: thanks, or why one isn't due yet.
/// The bar's action calls [_LeaveReviewCardState.open].
class _LeaveReviewCard extends StatefulWidget {
  const _LeaveReviewCard({
    super.key,
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

/// Whether a bundle task's review is ready, waiting, or already left.
enum _ReviewGate { ready, waiting, alreadyReviewed }

class _LeaveReviewCardState extends State<_LeaveReviewCard> {
  bool _submitted = false;

  /// Any bundle task reviews by bundle id, so its gate must be resolved.
  String? get _bundleId => widget.job.bundleId;

  /// Null for ordinary jobs (always ready) or while a gate is resolving.
  _ReviewGate? _gate;

  @override
  void initState() {
    super.initState();
    if (_bundleId == null) {
      _gate = _ReviewGate.ready;
    } else {
      _resolveGate(_bundleId!);
    }
  }

  /// Bundle task: already reviewed wins; otherwise the review opens once
  /// no other task of this provider in the bundle is still in progress.
  Future<void> _resolveGate(String bundleId) async {
    final me = context.read<AuthController>().user;
    if (me == null) return;
    // Read both repositories before the first await so `context` isn't
    // used across an async gap.
    final reviews = context.read<ReviewRepository>();
    final jobs = context.read<JobRepository>();
    try {
      final alreadyReviewed = await reviews.hasReviewed(
        revieweeId: widget.revieweeId,
        jobId: widget.job.id,
        reviewerId: me.uid,
        bundleId: bundleId,
      );
      if (alreadyReviewed) {
        if (mounted) setState(() => _gate = _ReviewGate.alreadyReviewed);
        return;
      }
      final tasks = await jobs.getBundleTasks(bundleId);
      final providerId = widget.job.acceptedProviderId;
      final stillGoing = tasks.any(
        (t) =>
            t.acceptedProviderId == providerId &&
            t.status == JobStatus.inProgress,
      );
      if (mounted) {
        setState(
          () => _gate = stillGoing ? _ReviewGate.waiting : _ReviewGate.ready,
        );
      }
    } catch (_) {
      // The write is deduped server-side, so fail open on a failed lookup.
      if (mounted) setState(() => _gate = _ReviewGate.ready);
    }
  }

  /// Whether a review is due right now (not yet left, gate open).
  bool get canReview => !_submitted && _gate == _ReviewGate.ready;

  Future<void> open() async {
    final me = context.read<AuthController>().user;
    if (me == null) return;
    final ok = await LeaveReviewSheet.show(
      context,
      job: widget.job,
      reviewer: me,
      revieweeId: widget.revieweeId,
      revieweeName: widget.revieweeName,
      bundleId: _bundleId,
    );
    if (ok == true && mounted) setState(() => _submitted = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_submitted || _gate == _ReviewGate.alreadyReviewed) {
      return InfoBanner(
        icon: Icons.check_circle_outline,
        title: 'Review submitted',
        body: 'Thanks, your feedback helps keep FairBid fair.',
        color: context.fairbid.successText,
      );
    }
    if (_gate == _ReviewGate.waiting) {
      return InfoBanner(
        icon: Icons.hourglass_empty,
        title: 'Almost there',
        body:
            'You can review ${widget.revieweeName} once all their tasks '
            'in this bundle are done.',
      );
    }
    // Resolving a bundle task's gate, or a review is due (the bar offers it).
    return const SizedBox.shrink();
  }
}

/// The job's activity log, newest first, in a collapsed [ExpansionTile]
/// whose header shows the latest event.
class _ActivityTimeline extends StatefulWidget {
  const _ActivityTimeline({required this.job});
  final Job job;

  @override
  State<_ActivityTimeline> createState() => _ActivityTimelineState();
}

class _ActivityTimelineState extends State<_ActivityTimeline> {
  late final Stream<List<JobEvent>> _events = context
      .read<JobRepository>()
      .watchJobEvents(widget.job.id);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<List<JobEvent>>(
      stream: _events,
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
        // Already newest-first; reversing would pick the wrong `latest`.
        final events = snapshot.data ?? const <JobEvent>[];
        if (events.isEmpty) return const SizedBox.shrink();
        final latest = events.first;

        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.fairbid.borderSubtle),
          ),
          child: Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 20),
              childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              title: Text('Activity', style: theme.textTheme.titleLarge),
              subtitle: Row(
                children: [
                  Icon(
                    _timelineIcon(latest.type),
                    size: 14,
                    color: _timelineColor(context, latest.type),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${latest.title} · ${timeAgo(latest.at)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              children: [
                for (final (i, event) in events.indexed)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: i == events.length - 1 ? 0 : 12,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          _timelineIcon(event.type),
                          size: 18,
                          color: _timelineColor(context, event.type),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                event.title,
                                style: theme.textTheme.bodyMedium,
                              ),
                              Text(
                                timeAgo(event.at),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The bottom bar once resolved: one main button plus a short info line,
/// or a muted waiting line when it's the other party's move.
class _ResolvedBar {
  const _ResolvedBar({this.action, this.waitingLine});
  final NextAction? action;
  final String? waitingLine;
}

/// Whether the bar takes its action from the job's stages.
bool _milestoneAware(JobDetailViewModel vm, Job job) =>
    (vm.role == JobViewerRole.owner ||
        vm.role == JobViewerRole.acceptedProvider) &&
    job.status == JobStatus.inProgress;

_ResolvedBar _resolveMilestoneBar(
  JobDetailViewModel vm,
  List<Milestone>? milestones,
) {
  final isOwner = vm.role == JobViewerRole.owner;

  if (milestones == null || milestones.isEmpty) {
    return _ResolvedBar(action: vm.primaryAction, waitingLine: vm.waitingLine);
  }

  final current = milestones.cast<Milestone?>().firstWhere(
    (m) => !_isMilestoneTerminal(m!.status),
    orElse: () => null,
  );
  if (current == null) {
    return _ResolvedBar(action: vm.primaryAction, waitingLine: vm.waitingLine);
  }
  final index = milestones.indexOf(current) + 1;
  final amount = formatRm(current.amountSen);

  switch (current.status) {
    case MilestoneStatus.funded:
      if (!isOwner) {
        return _ResolvedBar(
          action: NextAction(
            label: 'Mark as delivered',
            kind: JobActionKind.markDelivered,
            contextLine: current.description,
          ),
        );
      }
      return _ResolvedBar(
        waitingLine: milestones.length == 1
            ? '$amount is secured in escrow. Waiting for the provider to '
                  'deliver.'
            : 'Waiting for the provider to deliver milestone $index.',
      );
    case MilestoneStatus.submitted:
      if (isOwner) {
        return _ResolvedBar(
          action: NextAction(
            label: 'Release $amount',
            kind: JobActionKind.releaseMilestone,
            contextLine: current.description,
          ),
        );
      }
      return _ResolvedBar(
        waitingLine: milestones.length == 1
            ? 'Marked as delivered. Waiting for the client to review the '
                  'work and release $amount.'
            : 'Marked as delivered. Waiting for the client to review '
                  'milestone $index.',
      );
    case MilestoneStatus.disputed:
      return _ResolvedBar(
        waitingLine: 'Milestone $index is on hold while an admin reviews it.',
      );
    default:
      return _ResolvedBar(
        action: vm.primaryAction,
        waitingLine: vm.waitingLine,
      );
  }
}

/// The pinned bottom bar; hidden when the viewer has no action or waiting
/// line (e.g. a losing bidder).
class _Bar extends StatelessWidget {
  const _Bar({
    required this.action,
    required this.waitingLine,
    required this.busy,
    required this.onAction,
  });
  final NextAction? action;
  final String? waitingLine;
  final ValueNotifier<bool> busy;
  final void Function(JobActionKind kind) onAction;

  @override
  Widget build(BuildContext context) {
    if (action == null && (waitingLine == null || waitingLine!.isEmpty)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        border: Border(top: BorderSide(color: context.fairbid.borderSubtle)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
          child: action == null
              ? Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        waitingLine!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (action!.contextLine != null) ...[
                      Text(
                        action!.contextLine!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                    ValueListenableBuilder<bool>(
                      valueListenable: busy,
                      builder: (context, busy, _) => PrimaryButton(
                        label: action!.label,
                        busy: busy,
                        onPressed: () => onAction(action!.kind),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
