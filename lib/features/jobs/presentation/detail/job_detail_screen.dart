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
import '../bid/submit_bid_sheet.dart';
import '../bid/submit_bundle_bid_sheet.dart';
import '../widgets/bid_card.dart';
import '../widgets/insufficient_balance_dialog.dart';
import 'job_address_card.dart';
import 'job_detail_view_model.dart';
import 'job_video_player.dart';
import 'milestone_section.dart';
import 'photo_viewer_screen.dart';
import 'record_handover_sheet.dart';

/// Full job detail. One [CustomScrollView] with a FIXED slot order for every
/// viewer - a status headline, hero facts, the counterparty, description and
/// media, bids (or the provider's own bid action), the milestone tracker,
/// working details (address + chat), a review prompt and the activity
/// timeline - only *presence* varies by [JobDetailViewModel], never order.
/// A pinned bottom bar shows the one role-resolved action the viewer can
/// take right now; destructive/rare actions (cancel, request cancellation)
/// live in the app bar's overflow menu instead of competing for space in
/// the body.
class JobDetailScreen extends StatefulWidget {
  const JobDetailScreen({super.key, required this.jobId});

  final String jobId;

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
            appBar: AppBar(title: const Text('Job Details')),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        // Errors must be told apart from absence. A stream that fails
        // (offline, permission-denied, a rules change) also delivers a null
        // value, so this used to tell the requestor their own job had been
        // removed. A failed stream is terminal, hence the explicit re-open
        // instruction rather than a retry that would not work.
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('Job Details')),
            body: const SafeArea(
              child: EmptyState(
                icon: Icons.cloud_off,
                title: "Couldn't load this job",
                message: 'Check your connection, then go back and open the '
                    'job again.',
              ),
            ),
          );
        }
        final job = snapshot.data;
        if (job == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Job Details')),
            body: const SafeArea(
              child: EmptyState(
                icon: Icons.search_off_rounded,
                title: 'Job not found',
                message: 'It may have been removed by the requestor.',
              ),
            ),
          );
        }
        return _JobDetailBody(job: job);
      },
    );
  }
}

/// Whether [status] is a terminal escrow state - money has finished moving.
bool _isMilestoneTerminal(MilestoneStatus status) =>
    status == MilestoneStatus.released || status == MilestoneStatus.resolved;

/// Opens (lazily creating) the job's chat thread. Shared by the Working
/// Details message tile and the bottom bar's "Message provider/client" CTA.
Future<void> _openJobChat(BuildContext context, Job job) async {
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
      ..showSnackBar(
        const SnackBar(
          content: Text('Could not open the chat. Please try again.'),
        ),
      );
  }
}

/// Opens the right bid sheet for [job]: the bundle package sheet for a live
/// bundle task (rules refuse a per-job bid there), otherwise [SubmitBidSheet].
/// Reads the bundle/tasks/bid one-shot and concurrently, to avoid a
/// partially-cached task list; failures are caught here and shown as a snackbar.
Future<void> _openBidSheet(BuildContext context, Job job, AppUser bidder) async {
  if (!job.isLiveBundleTask) {
    SubmitBidSheet.show(context, job: job, bidder: bidder);
    return;
  }
  final bundleId = job.bundleId!;
  try {
    // A single `Future.wait` keeps exactly one `await`/`context.mounted`
    // check before every `context` use below, satisfying the linter's gap check.
    final results = await Future.wait<Object?>([
      context.read<BundleRepository>().getById(bundleId),
      context.read<JobRepository>().getBundleTasks(bundleId),
      context.read<BundleBidRepository>().getMyBundleBid(bundleId, bidder.uid),
    ]);
    if (!context.mounted) return;
    final bundle = results[0] as Bundle?;
    final tasks = results[1] as List<Job>;
    final existing = results[2] as BundleBid?;

    if (bundle == null || !bundle.biddingOpen) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This bundle is no longer accepting bids.'),
        ),
      );
      return;
    }
    final taskIds = tasks.map((t) => t.id).toSet();
    if (!bundle.taskIds.every(taskIds.contains)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Couldn't load every task in this bundle. Check your "
            'connection and try again.',
          ),
        ),
      );
      return;
    }
    SubmitBundleBidSheet.show(
      context,
      bundle: bundle,
      tasks: tasks,
      bidder: bidder,
      existing: existing,
    );
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Couldn't open the bid form. Please try again."),
      ),
    );
  }
}

/// Withdraws the provider's own bid on [jobId], after confirmation. Shared
/// by the inline "Withdraw bid" button and the bottom bar's secondary
/// Withdraw action.
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
  'completed' => Icons.check_circle_outline,
  'cancelled' => Icons.cancel_outlined,
  'handover' => Icons.inventory_2_outlined,
  _ => Icons.circle,
};

/// Colour shown against a timeline entry, keyed by [JobEvent.type], matching
/// the semantic colours used elsewhere (danger/warning/success/verified).
Color _timelineColor(BuildContext context, String type) => switch (type) {
  'cancelled' || 'disputed' => context.fairbid.danger,
  'refunded' => context.fairbid.warningText,
  'released' || 'completed' => context.fairbid.successText,
  _ => context.fairbid.verified,
};

/// Wraps [child] with [key] so [Scrollable.ensureVisible] can scroll a
/// bottom-bar CTA's target slot into view without the slot widget itself
/// needing to know about scroll anchoring.
Widget _keyed(GlobalKey key, Widget child) =>
    KeyedSubtree(key: key, child: child);

/// The screen's body once the job has loaded: the [JobDetailViewModel]-driven
/// scroll content plus the pinned bottom action bar.
class _JobDetailBody extends StatefulWidget {
  const _JobDetailBody({required this.job});
  final Job job;

  @override
  State<_JobDetailBody> createState() => _JobDetailBodyState();
}

class _JobDetailBodyState extends State<_JobDetailBody> {
  final _bidsSectionKey = GlobalKey();
  final _milestonesSectionKey = GlobalKey();
  final _reviewSectionKey = GlobalKey();

  late final String? _myUid = context.read<AuthController>().user?.uid;

  /// Only a provider looking at a still-open job that isn't theirs can have
  /// a live bid worth watching - the owner and the accepted provider never
  /// need this stream, and a job that has left `open` can never gain a new
  /// bidder. `job.status` only moves forward, so deciding this once at
  /// first build holds for the widget's whole lifetime.
  late final bool _tracksMyBid =
      _myUid != null && widget.job.status == JobStatus.open;

  late final Stream<Bid?>? _myBid = _tracksMyBid
      ? context.read<BidRepository>().watchMyBid(widget.job.id, _myUid!)
      : null;

  /// Only a provider on a still-open live bundle task can have a package bid
  /// worth watching - the only way the view model learns they cover it,
  /// since such a task never has a per-job [_myBid] of its own.
  late final bool _tracksMyBundleBid =
      _myUid != null &&
      widget.job.isLiveBundleTask &&
      context.read<AuthController>().user?.role == UserRole.provider;

  late final Stream<BundleBid?>? _myBundleBid = _tracksMyBundleBid
      ? context
          .read<BundleBidRepository>()
          .watchMyBundleBid(widget.job.bundleId!, _myUid!)
      : null;

  /// Feeds both the milestone tracker slot and the bottom bar's fund/
  /// release/deliver refinement, so they never disagree about which
  /// milestone is current.
  late final Stream<List<Milestone>>? _milestones =
      widget.job.acceptedProviderId != null
      ? context.read<MilestoneRepository>().watchMilestones(widget.job.id)
      : null;

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
  ) {
    switch (kind) {
      case JobActionKind.compareBids:
      case JobActionKind.yourBid:
        _scrollTo(_bidsSectionKey);
      case JobActionKind.reviewPlan:
      case JobActionKind.fundMilestone:
      case JobActionKind.releaseMilestone:
      case JobActionKind.proposeMilestones:
      case JobActionKind.markDelivered:
        _scrollTo(_milestonesSectionKey);
      case JobActionKind.message:
        _openJobChat(context, job);
      case JobActionKind.leaveReview:
        _scrollTo(_reviewSectionKey);
      case JobActionKind.submitBid:
        if (me != null) _openBidSheet(context, job, me);
      case JobActionKind.getVerified:
        context.push('/onboarding');
      case JobActionKind.viewBundle:
        context.push('/bundles/${job.bundleId}');
    }
  }

  /// Cancels [job]. A task of a still-open bundle can't be cancelled alone,
  /// so this cancels the whole bundle via [BundleRepository.cancelBundle];
  /// an ordinary job keeps using [JobRepository.cancelOpenJob].
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
            child: Text(isBundleTask ? 'Keep Bundle' : 'Keep Job'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.fairbid.danger,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(isBundleTask ? 'Cancel Bundle' : 'Cancel Job'),
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
      // The server writes these to be read by a requestor, so shown as-is.
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
            const Text(
              'The other party must agree before the job is '
              'cancelled. Funded milestones must be released or disputed '
              'first.',
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

  /// The overflow menu's single cancel-related entry, or null when there's
  /// none for this viewer/status (e.g. a cancellation is already pending -
  /// that's answered via the slot-3 response card instead).
  (String value, String label)? _cancelMenuEntry(
    Job job,
    JobDetailViewModel vm,
  ) {
    if (!vm.showCancel) return null;
    if (job.status == JobStatus.open) return ('cancel', 'Cancel job');
    if (job.hasPendingCancellation) return null;
    return ('request', 'Request cancellation');
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
    final cancelEntry = _cancelMenuEntry(job, vm);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            title: const Text('Job Details'),
            actions: [
              if (cancelEntry != null)
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'cancel') {
                      _cancelJob(context, job);
                    } else {
                      _requestCancellation(context, job);
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: cancelEntry.$1,
                      child: Text(cancelEntry.$2),
                    ),
                  ],
                ),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            sliver: SliverList(
              delegate: SliverChildListDelegate(
                _slots(context, job, me, myBid, vm),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _BottomActionBar(
        job: job,
        vm: vm,
        milestonesStream: _milestones,
        onAction: (kind) => _handleAction(context, job, me, kind),
        onWithdrawBid: myBid == null
            ? null
            : () => _withdrawBid(context, job.id, myBid.providerId),
      ),
    );
  }

  List<Widget> _slots(
    BuildContext context,
    Job job,
    AppUser? me,
    Bid? myBid,
    JobDetailViewModel vm,
  ) {
    final isOwner = vm.role == JobViewerRole.owner;
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
    add(job.isLiveBundleTask
        ? _BundleTaskBanner(job: job, isOwner: isOwner)
        : job.isBundleTask
            ? _ReleasedBundleTaskBanner(job: job, isOwner: isOwner)
            : null);
    add(
      vm.role == JobViewerRole.acceptedProvider &&
              job.status == JobStatus.inProgress &&
              job.startsAfterJobId != null
          ? _HandoverBanner(job: job)
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
                job: job,
                isOwner: isOwner,
                me: me,
                myBid: myBid,
              ),
            )
          : null,
    );
    add(
      vm.showMilestones
          ? _keyed(_milestonesSectionKey, MilestoneSection(job: job))
          : null,
    );
    add(vm.showAddress ? _WorkingDetails(job: job, isOwner: isOwner) : null);
    add(
      vm.showReviewPrompt
          ? _keyed(_reviewSectionKey, _ReviewPrompt(job: job, isOwner: isOwner))
          : null,
    );
    // An open job has only its lone "posted" event - not worth a card.
    add(job.status != JobStatus.open ? _ActivityTimeline(jobId: job.id) : null);

    return slots;
  }
}

/// Slot 2: one plain-language sentence saying whose turn it is.
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

/// Slot 2b: a bundle task explains itself, since it bids and gets cancelled
/// differently from an ordinary job.
class _BundleTaskBanner extends StatelessWidget {
  const _BundleTaskBanner({required this.job, required this.isOwner});
  final Job job;
  final bool isOwner;

  @override
  Widget build(BuildContext context) {
    final count = job.bundleTaskCount;
    return InfoBanner(
      icon: Icons.inventory_2_outlined,
      // The owner awards the whole posting from the bundle screen.
      trailing: isOwner
          ? TextButton(
              onPressed: () => context.push('/bundles/${job.bundleId}'),
              child: const Text('View bundle'),
            )
          : null,
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

/// Slot 2b (released variant): a task the bundle's award left unawarded -
/// from then on it takes ordinary bids and can be cancelled on its own, so
/// this replaces [_BundleTaskBanner] once `job.releasedAt` is set.
class _ReleasedBundleTaskBanner extends StatelessWidget {
  const _ReleasedBundleTaskBanner({required this.job, required this.isOwner});
  final Job job;
  final bool isOwner;

  @override
  Widget build(BuildContext context) {
    return InfoBanner(
      icon: Icons.inventory_2_outlined,
      // The owner can still see the bundle it came from.
      trailing: isOwner
          ? TextButton(
              onPressed: () => context.push('/bundles/${job.bundleId}'),
              child: const Text('View bundle'),
            )
          : null,
      title: 'Released from its bundle',
      body: "This task wasn't awarded with the rest of its bundle, so it "
          'now takes ordinary bids.',
    );
  }
}

/// Slot 2c: prompts the accepted provider of a task that starts after
/// another to record the site handover before starting. Hides itself once
/// the timeline already has a `handover` event.
class _HandoverBanner extends StatefulWidget {
  const _HandoverBanner({required this.job});
  final Job job;

  @override
  State<_HandoverBanner> createState() => _HandoverBannerState();
}

class _HandoverBannerState extends State<_HandoverBanner> {
  late final Stream<List<JobEvent>> _events =
      context.read<JobRepository>().watchJobEvents(widget.job.id);

  Future<void> _recordHandover(BuildContext context) async {
    final recorded =
        await RecordHandoverSheet.show(context, jobId: widget.job.id);
    if (recorded == true && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Handover recorded.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<JobEvent>>(
      stream: _events,
      builder: (context, snapshot) {
        final events = snapshot.data ?? const <JobEvent>[];
        if (events.any((e) => e.type == 'handover')) {
          return const SizedBox.shrink();
        }
        return InfoBanner(
          icon: Icons.inventory_2_outlined,
          title: 'Site handover',
          body: 'Record the site handover before you start.',
          trailing: TextButton(
            onPressed: () => _recordHandover(context),
            child: const Text('Record handover'),
          ),
        );
      },
    );
  }
}

/// Slot 3: a mid-flight cancellation request awaiting this viewer's answer.
/// Kept high in the fixed order because it demands attention.
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
              label: 'Accept & Cancel Job',
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

/// Slot 4: category, status, budget, location and deadline as compact tiles,
/// under the job's title and post time.
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
                label: 'Budget',
                value: job.budget!.label!,
              ),
            _FactTile(
              icon: Icons.location_on_outlined,
              label: 'Location',
              value: job.location.address,
            ),
            if (job.deadline != null)
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

/// Slot 5: the counterparty identity - the job poster for providers, the
/// assigned provider for the owner - unifying what used to be two
/// differently-shaped cards into one [UserChip]-based component. Taps
/// through to `/users/:uid`.
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
      label = 'Assigned Provider';
      uid = job.acceptedProviderId!;
      name = job.acceptedProviderName ?? 'Provider';
      photoUrl = null;
      subtitle = job.acceptedBidAmountSen != null
          ? 'Accepted bid: ${formatRm(job.acceptedBidAmountSen!)}'
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

/// Slot 6: the description (with its label-bolding), then photos, then video.
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
          SizedBox(
            height: 120,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: job.photoUrls.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) => InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => PhotoViewerScreen.show(
                  context,
                  photoUrls: job.photoUrls,
                  initialIndex: i,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    job.photoUrls[i],
                    width: 120,
                    height: 120,
                    // width/height only constrain layout; without cacheWidth
                    // each of these decodes at the full 1600px upload size,
                    // roughly 7.7MB of RGBA per thumbnail. A five-photo job
                    // cost ~38MB of bitmap to show a 600x120 strip.
                    cacheWidth:
                        (120 * MediaQuery.devicePixelRatioOf(context)).round(),
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

/// The job's description, bolding the "What needs doing" / "Access &
/// details" / "Expected outcome" section labels the AI description helper
/// writes (`functions/index.js`'s `DESCRIPTION_SYSTEM`), via simple
/// line-matching - no markdown dependency needed. A free-typed description
/// that doesn't use those labels renders unchanged.
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

/// Slot 7: the owner's live bid list with a sort toggle and Accept actions
/// while the job is open, or the provider's own submit/withdraw bid action.
class _BidsOrBidAction extends StatefulWidget {
  const _BidsOrBidAction({
    required this.job,
    required this.isOwner,
    required this.me,
    required this.myBid,
  });
  final Job job;
  final bool isOwner;
  final AppUser? me;

  /// The provider's own live bid on [job] (or null), already resolved by
  /// [_JobDetailBodyState] - threaded down rather than re-subscribed here so
  /// this slot doesn't open a second, redundant `watchMyBid` stream.
  final Bid? myBid;

  @override
  State<_BidsOrBidAction> createState() => _BidsOrBidActionState();
}

class _BidsOrBidActionState extends State<_BidsOrBidAction> {
  _BidSort _sort = _BidSort.bestValue;

  /// Provider id of the bid whose accept is in flight, or null. `acceptBid` is
  /// a server transaction that can take a second or two, and without any
  /// in-flight state the screen sat completely unchanged: users tapped Accept
  /// again, sometimes on a different provider, then lost the race to their own
  /// first call and got the confusing "this job changed" snackbar.
  String? _acceptingProviderId;

  /// Live trust scores for the providers who have bid, keyed by uid.
  ///
  /// The bid documents carry a score copied at bid time, which drifts as the
  /// provider earns reviews, completes jobs or loses a dispute. Ranking on the
  /// stale copy meant Best Value ordered bids by old reputation while the
  /// provider's own profile showed the current one. Resolved once per distinct
  /// set of bidders and cached, so scrolling and re-sorting do not refetch.
  Map<String, ProviderTrust> _liveTrust = const {};
  String? _trustFetchedFor;

  /// Fetches live trust for [bids] unless the same bidders were already
  /// resolved. Safe to call from build: it no-ops once settled.
  void _resolveTrust(List<Bid> bids) {
    final key = (bids.map((b) => b.providerId).toList()..sort()).join(',');
    if (key.isEmpty || key == _trustFetchedFor) return;
    _trustFetchedFor = key;
    context
        .read<PublicProfileRepository>()
        .fetchTrust(bids.map((b) => b.providerId))
        .then((trust) {
      if (mounted) setState(() => _liveTrust = trust);
    }).catchError((_) {
      // Fall back to the stored snapshot; a failed reputation lookup must
      // never blank out the bid list.
    });
  }

  // Cached so changing the sort (a setState) re-orders the already-loaded bids
  // client-side instead of resubscribing to Firestore and flashing the spinner.
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
            child: const Text('Accept Bid'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Capture the outcome, then clear the busy state *before* reporting it.
    // Reporting inside the catch would leave the button spinning behind the
    // error dialog for as long as the user took to read it.
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
      // Hiring someone is the largest commitment in the app; confirm it in the
      // hand as well as on screen. Deliberately not awaited: a haptic failure
      // must never surface as a failed accept.
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

        // Kick off (or skip) the live reputation lookup, then apply whatever
        // has resolved. Until it lands, the bid's own snapshot is used, so the
        // list renders immediately rather than waiting on a second query.
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

        // Composite needs the cheapest bid; compute it once and share it with
        // the sort and the Best Value badge so all three agree.
        final lowestSen = bids.map((b) => b.amountSen).reduce(min);
        bids.sort(switch (_sort) {
          _BidSort.price => (a, b) => a.amountSen.compareTo(b.amountSen),
          _BidSort.trustScore => (a, b) => b.providerTrustScore.compareTo(
            a.providerTrustScore,
          ),
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
                  ButtonSegment(
                    value: _BidSort.trustScore,
                    label: Text('Trust'),
                  ),
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

/// Submit-or-withdraw, driven by whether the provider already has a live
/// bid. [myBid] is the already-resolved value from
/// [_JobDetailBodyState]'s own cached `watchMyBid` stream - this widget
/// stays a plain [StatelessWidget] and never opens its own second
/// subscription to the same document.
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
        onPressed: () => _openBidSheet(context, job, user),
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

/// Slot 9: the private service-address card, plus the message/chat entry.
class _WorkingDetails extends StatelessWidget {
  const _WorkingDetails({required this.job, required this.isOwner});
  final Job job;
  final bool isOwner;

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
    );
  }
}

/// Slot 10: the leave-a-review prompt on a completed job.
class _ReviewPrompt extends StatelessWidget {
  const _ReviewPrompt({required this.job, required this.isOwner});
  final Job job;
  final bool isOwner;

  @override
  Widget build(BuildContext context) {
    return isOwner
        ? _LeaveReviewCard(
            job: job,
            revieweeId: job.acceptedProviderId!,
            revieweeName: job.acceptedProviderName ?? 'Provider',
          )
        : _LeaveReviewCard(
            job: job,
            revieweeId: job.requestorId,
            revieweeName: job.requestorName,
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

/// Whether a completed bundle task's review is ready, still waiting on the
/// provider's other tasks in the same bundle, or already left.
enum _ReviewGate { ready, waiting, alreadyReviewed }

class _LeaveReviewCardState extends State<_LeaveReviewCard> {
  bool _submitted = false;

  /// Any bundle task - released or still live - reviews by bundle id (the
  /// rules key on `bundleId` alone) and needs the gate resolved first.
  String? get _bundleId => widget.job.bundleId;

  /// Null while an ordinary job's gate is trivially "ready", or while a
  /// bundle task's gate is still being resolved.
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

  /// For any bundle task: already reviewed for this bundle wins outright;
  /// otherwise the review only opens once none of this provider's other
  /// tasks in the bundle are still in progress.
  Future<void> _resolveGate(String bundleId) async {
    final me = context.read<AuthController>().user;
    if (me == null) return;
    // Read both repositories before the first await, so nothing below reads
    // `context` across an async gap.
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
      // leaveReview's own dedupe transaction still guards the actual write,
      // so fail open rather than block the prompt on a failed lookup.
      if (mounted) setState(() => _gate = _ReviewGate.ready);
    }
  }

  Future<void> _open() async {
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
        body: 'You can review ${widget.revieweeName} once all their tasks '
            'in this bundle are done.',
      );
    }
    if (_gate == null) {
      // Resolving a bundle task's gate.
      return const SizedBox.shrink();
    }
    return PrimaryButton(
      label: 'Review ${widget.revieweeName}',
      trailingIcon: Icons.star_outline,
      onPressed: _open,
    );
  }
}

/// Slot 11: the job's server-written activity log (plan §3.x), newest event
/// first, inside an [ExpansionTile] collapsed by default with the latest
/// event summarised in the header - so the most relevant entry is the
/// easiest to reach, not the hardest.
class _ActivityTimeline extends StatefulWidget {
  const _ActivityTimeline({required this.jobId});
  final String jobId;

  @override
  State<_ActivityTimeline> createState() => _ActivityTimelineState();
}

class _ActivityTimelineState extends State<_ActivityTimeline> {
  late final Stream<List<JobEvent>> _events = context
      .read<JobRepository>()
      .watchJobEvents(widget.jobId);

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
        // Already newest-first: watchJobEvents orders descending so its limit
        // keeps the recent tail. Reversing here again would put the oldest
        // entry at the top and pick the wrong `latest`.
        final events = snapshot.data ?? const <JobEvent>[];
        if (events.isEmpty) return const SizedBox.shrink();
        final latest = events.first;

        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
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
                              if (event.note != null &&
                                  event.note!.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  event.note!,
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ],
                              if (event.photoUrls.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                _TimelinePhotos(urls: event.photoUrls),
                              ],
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

/// Thumbnail strip for a timeline event's photos (e.g. `handover`). Tapping
/// one opens the same full-size viewer the job's own Photos list uses.
class _TimelinePhotos extends StatelessWidget {
  const _TimelinePhotos({required this.urls});
  final List<String> urls;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (i, url) in urls.indexed)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () =>
                PhotoViewerScreen.show(context, photoUrls: urls, initialIndex: i),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                url,
                width: 64,
                height: 64,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => Container(
                  width: 64,
                  height: 64,
                  color: context.fairbid.borderSubtle,
                  child: Icon(Icons.broken_image_outlined,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The pinned bottom action bar: exactly one role-resolved primary CTA plus
/// a short context/money line, or (when it's the other party's move) a
/// muted waiting line instead. Hidden entirely - never disabled - when the
/// viewer has no action at all (a losing bidder, an outsider). Once the job
/// is in progress, milestone data refines the pure view model's generic
/// "Message provider/client" fallback into "Fund RM X" / "Release RM X" /
/// "Mark delivered" / "Propose milestones" for whoever's turn it is.
class _BottomActionBar extends StatelessWidget {
  const _BottomActionBar({
    required this.job,
    required this.vm,
    required this.milestonesStream,
    required this.onAction,
    this.onWithdrawBid,
  });

  final Job job;
  final JobDetailViewModel vm;
  final Stream<List<Milestone>>? milestonesStream;
  final void Function(JobActionKind kind) onAction;
  final VoidCallback? onWithdrawBid;

  bool get _milestoneAware =>
      (vm.role == JobViewerRole.owner ||
          vm.role == JobViewerRole.acceptedProvider) &&
      job.status == JobStatus.inProgress &&
      milestonesStream != null;

  @override
  Widget build(BuildContext context) {
    if (_milestoneAware) {
      return StreamBuilder<List<Milestone>>(
        stream: milestonesStream,
        builder: (context, snapshot) {
          final resolved = _resolveMilestoneBar(vm, snapshot.data);
          return _Bar(
            action: resolved.action,
            waitingLine: resolved.waitingLine,
            onAction: onAction,
            onWithdrawBid: onWithdrawBid,
          );
        },
      );
    }
    return _Bar(
      action: vm.primaryAction,
      waitingLine: vm.waitingLine,
      onAction: onAction,
      onWithdrawBid: onWithdrawBid,
    );
  }
}

class _ResolvedBar {
  const _ResolvedBar({this.action, this.waitingLine});
  final NextAction? action;
  final String? waitingLine;
}

_ResolvedBar _resolveMilestoneBar(
  JobDetailViewModel vm,
  List<Milestone>? milestones,
) {
  final isOwner = vm.role == JobViewerRole.owner;

  if (milestones == null) {
    return _ResolvedBar(action: vm.primaryAction, waitingLine: vm.waitingLine);
  }
  if (milestones.isEmpty) {
    if (!isOwner) {
      return const _ResolvedBar(
        action: NextAction(
          label: 'Propose milestones',
          kind: JobActionKind.proposeMilestones,
        ),
      );
    }
    return _ResolvedBar(action: vm.primaryAction, waitingLine: vm.waitingLine);
  }

  final planApproved = !milestones.any(
    (m) => m.status == MilestoneStatus.proposed,
  );
  if (!planApproved) {
    if (isOwner) {
      return const _ResolvedBar(
        action: NextAction(
          label: 'Review the plan',
          kind: JobActionKind.reviewPlan,
        ),
      );
    }
    return const _ResolvedBar(
      waitingLine: 'Waiting for the client to approve the plan.',
    );
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
    case MilestoneStatus.pending:
      if (isOwner) {
        return _ResolvedBar(
          action: NextAction(
            label: 'Fund $amount',
            kind: JobActionKind.fundMilestone,
            contextLine: current.description,
          ),
        );
      }
      return _ResolvedBar(
        waitingLine: 'Waiting for the client to fund milestone $index.',
      );
    case MilestoneStatus.funded:
      if (!isOwner) {
        return _ResolvedBar(
          action: NextAction(
            label: 'Mark delivered',
            kind: JobActionKind.markDelivered,
            contextLine: current.description,
          ),
        );
      }
      return _ResolvedBar(
        waitingLine: 'Waiting for the provider to deliver milestone $index.',
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
        waitingLine: 'Waiting for the client to review milestone $index.',
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

class _Bar extends StatelessWidget {
  const _Bar({
    required this.action,
    required this.waitingLine,
    required this.onAction,
    this.onWithdrawBid,
  });
  final NextAction? action;
  final String? waitingLine;
  final void Function(JobActionKind kind) onAction;
  final VoidCallback? onWithdrawBid;

  @override
  Widget build(BuildContext context) {
    if (action == null && (waitingLine == null || waitingLine!.isEmpty)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
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
                    PrimaryButton(
                      label: action!.label,
                      onPressed: () => onAction(action!.kind),
                    ),
                    // Stacked (not side-by-side): the shared button theme's
                    // `minimumSize` is `Size.fromHeight`, i.e. an *infinite*
                    // minimum width, which two buttons can't both claim in
                    // one Row without an awkward fixed split.
                    if (action!.secondaryLabel != null &&
                        onWithdrawBid != null) ...[
                      const SizedBox(height: 8),
                      SecondaryButton(
                        label: action!.secondaryLabel!,
                        onPressed: onWithdrawBid,
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}
