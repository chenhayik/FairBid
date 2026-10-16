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
import '../../../../core/util/visit_time.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/form_widgets.dart';
import '../../../../core/widgets/keyed_stream_builder.dart';
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
import 'appointment_card.dart';
import 'job_address_card.dart';
import 'job_detail_view_model.dart';
import 'job_video_player.dart';
import 'milestone_section.dart';
import 'photo_strip.dart';
import 'propose_time_sheet.dart';

/// What:   Job detail screen for any viewer.
/// Input:  Job via JobRepository.watchJob(jobId) (job_repository.dart); [fromBundle] from ?from=bundle.
/// Output: Loading/error/not-found state, else _JobDetailBody.
class JobDetailScreen extends StatelessWidget {
  const JobDetailScreen({
    super.key,
    required this.jobId,
    this.fromBundle = false,
  });

  final String jobId;

  /// Makes "View bundle" pop back instead of pushing.
  final bool fromBundle;

  @override
  Widget build(BuildContext context) {
    return KeyedStreamBuilder<Job?>(
      cacheKey: jobId,
      create: () => context.read<JobRepository>().watchJob(jobId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Scaffold(
            appBar: AppBar(title: const Text('Job details')),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        // A failed stream also emits null; don't mistake it for a removed job.
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
        return _JobDetailBody(job: job, fromBundle: fromBundle);
      },
    );
  }
}

/// What:   Opens (or creates) the job's chat thread.
/// Input:  [job]; ChatRepository.openConversation(job) (chat_repository.dart).
/// Output: Pushes `/messages/{id}`; a snackbar if it fails.
Future<void> _openJobChat(BuildContext context, Job job) async {
  try {
    final id = await context.read<ChatRepository>().openConversation(job);
    if (!context.mounted) return;
    context.push('/messages/$id');
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Could not open the chat. Please try again.'),
        ),
      );
  }
}

/// What:   Withdraws the provider's own bid on a job.
/// Input:  [jobId] and the provider's [uid].
/// Output: After a confirm dialog, BidRepository.withdrawBid() with a snackbar for success or failure.
Future<void> _withdrawBid(
  BuildContext context,
  String jobId,
  String uid,
) async {
  final confirmed = await showConfirmDialog(
    context,
    title: 'Withdraw your bid?',
    body: 'Your bid will be removed from this job. You can bid again while '
        'the job is still open.',
    actionLabel: 'Withdraw',
  );
  if (!confirmed || !context.mounted) return;
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

/// What:   Icon for a timeline event.
/// Input:  Event [type] from JobEvent (job_event.dart).
/// Output: Matching icon, or a plain circle for unknown types.
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
  'appointment_proposed' => Icons.event_outlined,
  'appointment_confirmed' => Icons.event_available_outlined,
  'appointment_withdrawn' => Icons.event_busy_outlined,
  'on_the_way' => Icons.directions_car_outlined,
  'arrived' => Icons.place_outlined,
  _ => Icons.circle,
};

/// What:   Colour for a timeline event.
/// Input:  Event [type].
/// Output: Red for cancelled/disputed, amber for refunded/withdrawn, green for completed events, else the verified blue.
Color _timelineColor(BuildContext context, String type) => switch (type) {
  'cancelled' || 'disputed' => context.fairbid.danger,
  'refunded' => context.fairbid.warningText,
  'released' || 'completed' || 'appointment_confirmed' || 'arrived' =>
    context.fairbid.successText,
  'appointment_withdrawn' => context.fairbid.warningText,
  _ => context.fairbid.verified,
};

/// What:   Loaded job body: the sections plus the pinned bottom bar.
/// Input:  [job] from JobDetailScreen; own bids and milestones via streams opened here.
/// Output: Scaffold; the bar's actions open sheets, dialogs or chat.
class _JobDetailBody extends StatefulWidget {
  const _JobDetailBody({required this.job, required this.fromBundle});
  final Job job;
  final bool fromBundle;

  @override
  State<_JobDetailBody> createState() => _JobDetailBodyState();
}

class _JobDetailBodyState extends State<_JobDetailBody> {
  final _bidListKey = GlobalKey<_BidsOrBidActionState>();

  // Typed so the bottom bar can call into those sections.
  final _milestonesKey = GlobalKey<MilestoneSectionState>();
  final _reviewKey = GlobalKey<_LeaveReviewCardState>();
  final _appointmentKey = GlobalKey<AppointmentCardState>();

  /// True while a milestone action runs; the bar shows busy.
  final _actionBusy = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _actionBusy.dispose();
    super.dispose();
  }

  late final String? _myUid = context.read<AuthController>().user?.uid;

  /// Open jobs only; status only moves forward, so deciding once is enough.
  late final bool _tracksMyBid =
      _myUid != null && widget.job.status == JobStatus.open;

  late final Stream<Bid?>? _myBid = _tracksMyBid
      ? context.read<BidRepository>().watchMyBid(widget.job.id, _myUid!)
      : null;

  /// Providers on an open bundle task bid on the package, not the task.
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

  /// Opened on first need: a provider can be awarded while this is open.
  Stream<List<Milestone>>? _milestoneStream;
  /// What:   Milestone stream, opened on first use.
  /// Output: MilestoneRepository.watchMilestones(), or null until a provider is accepted.
  Stream<List<Milestone>>? get _milestones {
    if (widget.job.acceptedProviderId == null) return null;
    return _milestoneStream ??= context
        .read<MilestoneRepository>()
        .watchMilestones(widget.job.id);
  }

  /// What:   Scrolls the page to a section.
  /// Input:  GlobalKey of the target widget.
  void _scrollTo(GlobalKey key) {
    final target = key.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: motion(context, const Duration(milliseconds: 300)),
      curve: Curves.easeInOut,
    );
  }

  /// What:   Runs the bottom bar's button.
  /// Input:  The [kind] from the view model's NextAction (job_detail_view_model.dart), job, viewer and own bid.
  /// Output: Opens the matching sheet, chat or screen, or calls into the section that owns the action.
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
          _scrollTo(_bidListKey);
        }
      case JobActionKind.editBid:
        if (me != null) {
          SubmitBidSheet.show(context, job: job, bidder: me, existing: myBid);
        }
      case JobActionKind.releaseMilestone:
      case JobActionKind.markDelivered:
        _milestonesKey.currentState?.runCurrentAction();
      case JobActionKind.proposeTime:
        ProposeTimeSheet.show(context, job);
      case JobActionKind.confirmTime:
        _appointmentKey.currentState?.confirm();
      case JobActionKind.message:
        _openJobChat(context, job);
      case JobActionKind.leaveReview:
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

  /// What:   Opens the job's bundle.
  /// Output: Pops back if we came from that bundle, else pushes `/bundles/{id}?fromTask={jobId}`.
  void _viewBundle(BuildContext context, Job job) {
    if (widget.fromBundle && context.canPop()) {
      context.pop();
    } else {
      context.push('/bundles/${job.bundleId}?fromTask=${job.id}');
    }
  }

  /// What:   Cancels an open job.
  /// Output: After a confirm dialog, cancels the job via JobRepository.cancelOpenJob(), or the whole bundle via BundleRepository.cancelBundle()
  ///         for a live bundle task.
  Future<void> _cancelJob(BuildContext context, Job job) async {
    final isBundleTask = job.isLiveBundleTask;
    final taskCount = job.bundleTaskCount;
    final bundleBody = taskCount != null
        ? 'All $taskCount tasks in this bundle will be cancelled and '
              'providers will no longer be able to bid. This cannot be undone.'
        : 'Every task in this bundle will be cancelled and providers will '
              'no longer be able to bid. This cannot be undone.';
    final confirmed = await showConfirmDialog(
      context,
      title: isBundleTask ? 'Cancel this bundle?' : 'Cancel this job?',
      body: isBundleTask
          ? bundleBody
          : 'Your job posting will be closed and providers will no '
                'longer be able to bid. This cannot be undone.',
      cancelLabel: isBundleTask ? 'Keep bundle' : 'Keep job',
      actionLabel: isBundleTask ? 'Cancel bundle' : 'Cancel job',
      danger: true,
    );
    if (!confirmed || !context.mounted) return;
    try {
      if (isBundleTask) {
        await context.read<BundleRepository>().cancelBundle(job.bundleId!);
      } else {
        await context.read<JobRepository>().cancelOpenJob(job.id);
      }
    } on BundleRejectedException catch (e) {
      // Server-written for requestors, so shown as-is.
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

  /// What:   Asks the other party to cancel an in-progress job.
  /// Output: Dialog with an optional reason, then JobRepository.requestCancellation().
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
    await _runCall(
      context,
      () => context.read<JobRepository>().requestCancellation(
        job.id,
        reason: text.isEmpty ? null : text,
      ),
    );
  }

  /// What:   Dialog to propose a new agreed price.
  /// Input:  [job] current price (acceptedBidAmountSen).
  /// Output: Validated amount and required reason, sent via JobRepository.requestPriceChange().
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
    await _runCall(
      context,
      () => context.read<JobRepository>().requestPriceChange(
        job.id,
        newAmountSen: newSen,
        reason: text,
      ),
    );
  }

  /// What:   Why the price can't be changed now.
  /// Output: A reason (bundle task, open dispute, pending change or cancellation, 3 changes already), or null when it can.
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

  /// What:   Whether the "Problem with this job?" button applies.
  /// Output: True for the owner or hired provider on an in-progress job, or on an open one that can be cancelled.
  bool _showProblemButton(Job job, JobDetailViewModel vm) {
    final isParty = vm.role == JobViewerRole.owner ||
        vm.role == JobViewerRole.acceptedProvider;
    return isParty &&
        (job.status == JobStatus.inProgress ||
            (job.status == JobStatus.open && vm.showCancel));
  }

  /// What:   Why "Provider didn't show up" is unavailable.
  /// Output: A reason (no confirmed visit, under 30 minutes after it, provider arrived, dispute open, nothing in escrow,
  ///         work delivered), or null when it applies.
  String? _noShowBlocker(Job job, MilestoneSectionState? milestones) {
    final start = job.appointment?.startAt;
    if (start == null) return 'Only once a visit time is confirmed.';
    if (!DateTime.now().isAfter(start.add(const Duration(minutes: 30)))) {
      return 'Only 30 minutes after the visit time.';
    }
    if (job.arrivedAt != null) return 'The provider marked themselves arrived.';
    if (milestones?.hasOpenDispute == true) return 'A dispute is already open.';
    final milestone = milestones?.disputableMilestone;
    if (milestone == null) return 'Only once payment is held in escrow.';
    if (milestone.status == MilestoneStatus.submitted) {
      return 'The provider already marked the work delivered.';
    }
    return null;
  }

  /// What:   Sheet with every way out of a job.
  /// Output: Options (change price, raise dispute, no-show, cancel), each disabled with its reason when blocked; runs the picked one.
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
      if (inProgress && vm.role == JobViewerRole.owner)
        (
          "Provider didn't show up",
          Icons.person_off_outlined,
          _noShowBlocker(job, milestones),
          () => milestones?.raiseDispute(
            initialStatement: "The provider didn't show up for the visit on "
                '${formatVisitTime(job.appointment!.startAt)}.',
          ),
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
    final me = context.watch<AuthController>().user;
    return StreamBuilder<Bid?>(
      stream: _myBid,
      builder: (context, bidSnap) => StreamBuilder<BundleBid?>(
        stream: _myBundleBid,
        builder: (context, bundleSnap) =>
            _scaffold(context, me, bidSnap.data, bundleSnap.data),
      ),
    );
  }

  /// What:   Page scaffold for one build.
  /// Input:  Job, viewer, own bid and bundle bid.
  /// Output: Sections from [_slots] and the bottom bar; the bar waits on milestones when they decide its action.
  Widget _scaffold(
    BuildContext context,
    AppUser? me,
    Bid? myBid,
    BundleBid? myBundleBid,
  ) {
    final job = widget.job;
    final vm = buildJobDetailVm(job, me, myBid, myBundleBid: myBundleBid);
    final milestones = _milestones;
    // The guard is needed: old data survives a switch to a null stream.
    final aware = milestones != null && _milestoneAware(vm, job);
    return StreamBuilder<List<Milestone>>(
      stream: aware ? milestones : null,
      builder: (context, snapshot) {
        final bar = aware
            ? _resolveMilestoneBar(vm, job, snapshot.data)
            : _ResolvedBar(action: vm.primaryAction, waitingLine: vm.waitingLine);
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
                    children: _slots(
                      context,
                      job,
                      me,
                      myBid,
                      myBundleBid,
                      vm,
                      bar,
                    ),
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
      },
    );
  }

  /// What:   The page's sections in order.
  /// Output: Widgets spaced 16px apart; sections that don't apply are skipped.
  /// Notes:  Built eagerly so the bottom bar can reach them through their GlobalKeys.
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
    add(
      _milestoneAware(vm, job) && job.schedulingRequired
          ? AppointmentCard(key: _appointmentKey, job: job, isOwner: isOwner)
          : null,
    );
    // An unawarded task in a cancelled bundle shows nothing.
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
          ? _BidsOrBidAction(
              key: _bidListKey,
              job: job,
              isOwner: isOwner,
              me: me,
              myBid: myBid,
            )
          : null,
    );
    // showBids is false here; the bundle task has no bid of its own.
    add(
      vm.role == JobViewerRole.browser &&
              me != null &&
              job.isLiveBundleTask &&
              myBundleBid != null &&
              myBundleBid.status == BundleBidStatus.pending &&
              myBundleBid.coversTask(job.id)
          ? KeyedSubtree(
              key: _bidListKey,
              child: _YourBundleBidCard(job: job, bid: myBundleBid),
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
    // An open job has only its "posted" event.
    add(job.status != JobStatus.open ? _ActivityTimeline(job: job) : null);

    return slots;
  }
}

/// What:   "View bundle" text button for the bundle banners.
/// Output: The button, or null when [onTap] is null.
Widget? _viewBundleButton(VoidCallback? onTap) => onTap == null
    ? null
    : TextButton(onPressed: onTap, child: const Text('View bundle'));

/// What:   One-line status at the top of the page.
/// Input:  [vm] statusHeadline.
/// Output: Info icon beside the headline text.
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

/// What:   Banner explaining that a bundle task is bid on as a package.
/// Input:  [job]; [onViewBundle] from _JobDetailBodyState (null for the owner, whose bar has it).
/// Output: InfoBanner with an optional "View bundle" button.
class _BundleTaskBanner extends StatelessWidget {
  const _BundleTaskBanner({required this.job, this.onViewBundle});
  final Job job;

  final VoidCallback? onViewBundle;

  @override
  Widget build(BuildContext context) {
    final count = job.bundleTaskCount;
    return InfoBanner(
      icon: Icons.inventory_2_outlined,
      bottom: _viewBundleButton(onViewBundle),
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

/// What:   Banner for an awarded bundle task, naming its bundle.
/// Input:  [job]; bundle title via BundleRepository.getById() (bundle_repository.dart).
/// Output: InfoBanner with an optional "View bundle" button.
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
          bottom: _viewBundleButton(widget.onViewBundle),
          title: 'Part of a bundle',
          body:
              'Awarded as part of '
              '${title != null && title.isNotEmpty ? '"$title"' : 'a bundle'}.',
        );
      },
    );
  }
}

/// What:   Banner for a task released from its bundle (it takes ordinary bids).
/// Input:  [onViewBundle] from _JobDetailBodyState.
/// Output: InfoBanner with an optional "View bundle" button.
class _ReleasedBundleTaskBanner extends StatelessWidget {
  const _ReleasedBundleTaskBanner({this.onViewBundle});
  final VoidCallback? onViewBundle;

  @override
  Widget build(BuildContext context) {
    return InfoBanner(
      icon: Icons.inventory_2_outlined,
      bottom: _viewBundleButton(onViewBundle),
      title: 'Released from its bundle',
      body:
          "This task wasn't awarded with the rest of its bundle, so it "
          'now takes ordinary bids.',
    );
  }
}

/// What:   Card for a cancellation request waiting on this viewer.
/// Input:  [job] and [role]; JobRepository.respondToCancellation() (job_repository.dart).
/// Output: Agree/decline buttons; failures in a SnackBar.
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

  /// What:   Agree or decline handler.
  /// Output: JobRepository.respondToCancellation() via _runCall with busy state.
  Future<void> _respond(bool accept) async {
    setState(() => _busy = true);
    await _runCall(
      context,
      () => context.read<JobRepository>().respondToCancellation(
        widget.job.id,
        accept: accept,
      ),
    );
    if (mounted) setState(() => _busy = false);
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

/// What:   Runs a callable-backed action and shows failures in a snackbar.
/// Input:  [call]; [isRequestor] false when the viewer is the provider.
/// Output: Requestor low balance opens the top-up dialog; the provider sees a plain message instead.
Future<void> _runCall(
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

/// What:   Card for a pending price change.
/// Input:  [job] and [role]; JobRepository.respondToPriceChange()/withdrawPriceChange().
/// Output: Accept/decline for the responder, withdraw for the proposer.
class _PriceChangeCard extends StatefulWidget {
  const _PriceChangeCard({required this.job, required this.role});
  final Job job;
  final JobViewerRole role;

  @override
  State<_PriceChangeCard> createState() => _PriceChangeCardState();
}

class _PriceChangeCardState extends State<_PriceChangeCard> {
  bool _busy = false;

  /// What:   Runs one JobRepository call with busy state.
  /// Input:  [call] such as respondToPriceChange or withdrawPriceChange (job_repository.dart).
  /// Output: Sets [_busy] while it runs; failures show via _runCall.
  Future<void> _run(Future<void> Function(JobRepository repo) call) async {
    setState(() => _busy = true);
    final repo = context.read<JobRepository>();
    await _runCall(
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

/// What:   Fact tiles: category, status, budget, location and deadline.
/// Input:  [job].
/// Output: Rendered tiles.
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
            // Only while bidding is live; later it would read stale.
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

/// What:   One labelled fact (icon, label, value) in the hero section.
/// Input:  [icon], [label], [value]; optional [color] for the icon.
/// Output: Rounded tile on the subtle blue background.
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

/// What:   Card for the other party: the client, or the assigned provider.
/// Input:  [job]; [isOwnerView] picks which side.
/// Output: UserChip that opens `/users/:uid`.
class _CounterpartyCard extends StatelessWidget {
  const _CounterpartyCard({required this.job, required this.isOwnerView});
  final Job job;
  final bool isOwnerView;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, uid, name, photoUrl, subtitle) = isOwnerView
        ? (
            'Assigned provider',
            job.acceptedProviderId!,
            job.acceptedProviderName ?? 'Provider',
            null,
            job.acceptedBidAmountSen != null
                ? (job.originalBidAmountSen != null &&
                          job.originalBidAmountSen != job.acceptedBidAmountSen
                      ? 'Agreed price: ${formatRm(job.acceptedBidAmountSen!)} '
                            '(was ${formatRm(job.originalBidAmountSen!)})'
                      : 'Accepted bid: ${formatRm(job.acceptedBidAmountSen!)}')
                : null,
          )
        : ('Client', job.requestorId, job.requestorName, job.requestorPhotoUrl, null);
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

/// What:   Description, photos and video of a job.
/// Input:  [job].
/// Output: Rendered section.
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

/// What:   Job description with the AI helper's section labels in bold.
/// Input:  [text] from job.description.
/// Output: Rich text; other text is unchanged.
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

/// What:   Bid sort order.
/// Output: bestValue blends price and Trust Score; price is cheapest first.
enum _BidSort { bestValue, price }

/// What:   Best Value score for one bid.
/// Input:  [bid] and the cheapest bid's amount [lowestSen].
/// Output: PlatformConfig.priceWeight * (lowest / amount) + trustWeight * trust (trust scaled to 0-1); cheaper and more trusted scores higher.
/// Notes:  A "New" provider counts as the neutral baseline, not their hidden score.
double _compositeScore(Bid bid, int lowestSen) {
  final priceScore = lowestSen / bid.amountSen;
  final trust = (bid.providerScoreVisible
          ? bid.providerTrustScore
          : PlatformConfig.neutralTrustScore) /
      1000;
  return PlatformConfig.priceWeight * priceScore +
      PlatformConfig.trustWeight * trust;
}

/// What:   The owner's bid list (sort, Accept), or the provider's own bid action.
/// Input:  [job], [me], [myBid] (passed down to avoid a second watchMyBid stream); BidRepository.
/// Output: Bid cards or _BidAction; Accept runs BidRepository.acceptBid().
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

  final Bid? myBid;

  @override
  State<_BidsOrBidAction> createState() => _BidsOrBidActionState();
}

class _BidsOrBidActionState extends State<_BidsOrBidAction> {
  _BidSort _sort = _BidSort.bestValue;

  /// Provider id of the bid being accepted; shows progress and blocks double taps.
  String? _acceptingProviderId;

  /// Live trust by uid; bid snapshots go stale.
  Map<String, ProviderTrust> _liveTrust = const {};
  String? _trustFetchedFor;

  /// What:   Fetches live Trust Scores for the bidders, since bid snapshots go stale.
  /// Input:  [bids]; PublicProfileRepository.fetchTrust() (public_profile_repository.dart).
  /// Output: Fills [_liveTrust]; skips if already fetched for the same providers, and keeps the snapshot on failure.
  /// Notes:  Safe to call from build.
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

  List<Bid> _shownBids = const [];
  String? _bestValueId;

  /// What:   Whether the Compare sheet can open.
  /// Output: True with more than one bid shown and no accept in progress.
  bool get canCompare => _shownBids.length > 1 && _acceptingProviderId == null;

  /// What:   Opens the side-by-side bid comparison.
  /// Output: Starts [_accept] for the bid the owner picks.
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

  // Cached so a sort change doesn't resubscribe.
  late final Stream<List<Bid>> _bids = context.read<BidRepository>().watchBids(
    widget.job.id,
  );

  /// What:   Accept-bid flow for the owner.
  /// Input:  [bid]; the owner's available balance for the confirm text.
  /// Output: After a confirm dialog, BidRepository.acceptBid(); a balance shortfall opens the top-up dialog, a race shows a retry snackbar.
  Future<void> _accept(Bid bid) async {
    final available = context.read<AuthController>().user?.walletBalanceSen;
    final confirmed = await showConfirmDialog(
      context,
      title: 'Accept this bid?',
      body:
          '${bid.providerName} will be assigned to "${widget.job.title}" '
          'for ${formatRm(bid.amountSen)}. Other bids will be declined.'
          '\n\nThe ${formatRm(bid.amountSen)} moves into escrow now and is '
          'paid to them when you release it after the work is done.'
          '${available != null ? '\n\nYour available balance: '
                    '${formatRm(available)}.' : ''}',
      actionLabel: 'Accept bid',
    );
    if (!confirmed || !mounted) return;

    // Clear busy before reporting so the button doesn't spin behind the dialog.
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
      // Not awaited: a haptic failure must not fail the accept.
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

  /// What:   The owner's pending bids.
  /// Input:  BidRepository.watchBids() ([_bids]) with live Trust Scores swapped in.
  /// Output: Sort control and a BidCard per bid, or an empty/error state.
  /// How:    Best Value sorts by [_compositeScore] and badges the top bid; Price sorts by amount.
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

        // Until live trust resolves, the bid's own snapshot is used.
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

        // Best Value needs the cheapest bid.
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

/// What:   Sheet comparing all pending bids side by side.
/// Input:  Bids, trust and Best Value from _BidsOrBidActionState.
/// Output: Table marking cheapest, most trusted and Best Value; tapping a row starts its accept.
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

/// What:   The provider's own bid card with Withdraw, or a "bidding closed" note.
/// Input:  [myBid] from _BidsOrBidAction; BidRepository.withdrawBid().
/// Output: Rendered card; Withdraw confirms then removes the bid.
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
      // The server may lag at the deadline, so don't trust job.status alone.
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

/// What:   A provider's package-bid quote for this task.
/// Input:  [job] and [bid] (BundleBid).
/// Output: Rendered card; editing is the bottom bar's action.
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

/// What:   Private service address plus the chat entry.
/// Input:  [job]; [showMessage] is false when the bottom bar already offers chat.
/// Output: JobAddressCard and message tile.
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
        if (job.status == JobStatus.completed && job.appointment != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.event_available_outlined,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Visited on ${formatVisitTime(job.appointment!.startAt)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
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

/// What:   Review status of a completed job: thanks, or why one isn't due yet.
/// Input:  [job], [revieweeId], [revieweeName]; ReviewRepository.
/// Output: Banner; the bar's action calls [_LeaveReviewCardState.open].
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

/// What:   Whether a bundle task's review can be left yet.
/// Output: ready, waiting (another task of this provider is still in progress) or alreadyReviewed.
enum _ReviewGate { ready, waiting, alreadyReviewed }

class _LeaveReviewCardState extends State<_LeaveReviewCard> {
  bool _submitted = false;

  /// What:   The task's bundle id, if any.
  /// Notes:  A bundle task's gate must resolve before a review is offered.
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

  /// What:   Resolves the review gate for a bundle task.
  /// Input:  ReviewRepository.hasReviewed() and JobRepository.getBundleTasks().
  /// Output: Sets [_gate]: alreadyReviewed wins; else waiting while another of this provider's tasks is in progress, else ready.
  /// Notes:  Fails open to ready, since review writes are deduped server-side.
  Future<void> _resolveGate(String bundleId) async {
    final me = context.read<AuthController>().user;
    if (me == null) return;
    // Read before the first await; `context` can't cross an async gap.
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
      // Writes are deduped server-side, so fail open.
      if (mounted) setState(() => _gate = _ReviewGate.ready);
    }
  }

  /// What:   Whether a review is due right now.
  /// Output: True when not yet left and the gate is open.
  bool get canReview => !_submitted && _gate == _ReviewGate.ready;

  /// What:   Opens the review sheet.
  /// Output: LeaveReviewSheet; marks the card submitted on success.
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

/// What:   Collapsed activity log whose header shows the latest event.
/// Input:  Events via JobRepository.watchJobEvents() (job_repository.dart).
/// Output: AppCard with an ExpansionTile, newest first.
class _ActivityTimeline extends StatelessWidget {
  const _ActivityTimeline({required this.job});
  final Job job;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return KeyedStreamBuilder<List<JobEvent>>(
      cacheKey: job.id,
      create: () => context.read<JobRepository>().watchJobEvents(job.id),
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

        return AppCard(
          padding: EdgeInsets.zero,
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

/// What:   The bottom bar's resolved content.
/// Output: An [action] or a [waitingLine].
class _ResolvedBar {
  const _ResolvedBar({this.action, this.waitingLine});
  final NextAction? action;
  final String? waitingLine;
}

/// What:   Whether the bar takes its action from the job's stages.
/// Output: True for the owner or hired provider on an in-progress job.
bool _milestoneAware(JobDetailViewModel vm, Job job) =>
    (vm.role == JobViewerRole.owner ||
        vm.role == JobViewerRole.acceptedProvider) &&
    job.status == JobStatus.inProgress;

/// What:   Bottom bar content driven by the current milestone.
/// Input:  [vm], [job] and the streamed [milestones].
/// Output: Funded: provider Mark as delivered (or the visit-time bar). Submitted: owner Release. Otherwise a waiting line,
///         or the view model's own action when there is no current stage.
_ResolvedBar _resolveMilestoneBar(
  JobDetailViewModel vm,
  Job job,
  List<Milestone>? milestones,
) {
  final isOwner = vm.role == JobViewerRole.owner;

  if (milestones == null || milestones.isEmpty) {
    return _ResolvedBar(action: vm.primaryAction, waitingLine: vm.waitingLine);
  }

  final current = currentStage(milestones);
  if (current == null) {
    return _ResolvedBar(action: vm.primaryAction, waitingLine: vm.waitingLine);
  }
  final index = milestones.indexOf(current) + 1;
  final amount = formatRm(current.amountSen);

  switch (current.status) {
    case MilestoneStatus.funded:
      if (job.needsAppointment) return _visitTimeBar(vm, job);
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

/// What:   Bottom bar while a visit time is still to be agreed.
/// Input:  [vm] and [job] from _scaffold().
/// Output: Confirm (a proposal awaits), a waiting line, or Propose a time (provider).
_ResolvedBar _visitTimeBar(JobDetailViewModel vm, Job job) {
  final isOwner = vm.role == JobViewerRole.owner;
  final myUid = isOwner ? job.requestorId : job.acceptedProviderId;
  final otherName = isOwner
      ? job.acceptedProviderName ?? 'the provider'
      : job.requestorName;
  final proposal = job.appointmentProposal;
  if (proposal != null) {
    if (proposal.by == myUid) {
      return _ResolvedBar(
        waitingLine: 'Waiting for $otherName to confirm a visit time.',
      );
    }
    return _ResolvedBar(
      action: NextAction(
        label: proposal.options.length == 1
            ? 'Confirm visit time'
            : 'Choose a visit time',
        kind: JobActionKind.confirmTime,
      ),
    );
  }
  if (isOwner) {
    return _ResolvedBar(
      waitingLine: 'Waiting for $otherName to propose a visit time.',
    );
  }
  return const _ResolvedBar(
    action: NextAction(
      label: 'Propose a time',
      kind: JobActionKind.proposeTime,
      contextLine: 'Agree a visit time before you deliver.',
    ),
  );
}

/// What:   Pinned bottom bar.
/// Input:  [action] or [waitingLine] from _ResolvedBar; [busy] while a milestone action runs.
/// Output: Main button calling [onAction]; hidden with neither.
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
