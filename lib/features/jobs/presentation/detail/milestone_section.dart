import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/money.dart';
import '../../../../core/util/payment_log.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../auth/presentation/auth_controller.dart';
import '../../../disputes/presentation/raise_dispute_sheet.dart';
import '../../data/milestone_repository.dart';
import '../../domain/job.dart';
import '../../domain/milestone.dart';
import 'propose_milestones_sheet.dart';

/// The escrow milestone plan on a job detail: a hand-rolled vertical
/// progress tracker (never Flutter's `Stepper` — it owns its own scroll
/// physics and its fixed `StepState` can't express
/// proposed/pending/funded/submitted/released/disputed). One linear
/// sequence: Step 0 "Agree the plan", one step per milestone, then a
/// terminal "Job complete" step. The accepted provider proposes the plan;
/// then per milestone the requestor funds, the provider delivers and the
/// requestor releases payment. Releasing the last milestone completes the
/// job (server-side, via the `releaseMilestone` Cloud Function), which is
/// what unlocks reviews.
///
/// Only the *current* step — the first milestone not yet released, Step 0
/// while the plan is still unapproved, or any disputed milestone regardless
/// of position — renders expanded, with the section's only filled button.
/// Every other step collapses to one muted line; tapping a collapsed step
/// expands it.
class MilestoneSection extends StatefulWidget {
  const MilestoneSection({super.key, required this.job});

  final Job job;

  @override
  State<MilestoneSection> createState() => _MilestoneSectionState();
}

/// Terminal statuses: money has finished moving for this milestone (paid
/// out, or the legacy `resolved` alias — see [MilestoneStatus]'s doc).
bool _isTerminal(MilestoneStatus s) =>
    s == MilestoneStatus.released || s == MilestoneStatus.resolved;

class _MilestoneSectionState extends State<MilestoneSection> {
  // Cached so rebuilds don't resubscribe to Firestore.
  late final Stream<List<Milestone>> _milestones = context
      .read<MilestoneRepository>()
      .watchMilestones(widget.job.id);

  /// The milestone with an action call in flight, disabling its button — or
  /// [_planBusyKey] while a plan-level (approve/reject) action runs.
  String? _busyId;

  /// Sentinel [_busyId] value for plan-level actions (no single milestone id).
  static const _planBusyKey = '__plan__';

  /// The step (keyed by `'plan'`, a milestone id, or `'complete'`) the
  /// viewer tapped open manually. The current step is always expanded
  /// regardless of this.
  String? _expandedOverride;

  void _toggleExpand(String stepId) {
    setState(() {
      _expandedOverride = _expandedOverride == stepId ? null : stepId;
    });
  }

  Future<void> _fund(Milestone milestone) async {
    final repo = context.read<MilestoneRepository>();
    final confirmed = await _confirm(
      title: 'Fund this milestone?',
      body:
          '${formatRm(milestone.amountSen)} will be moved from your wallet '
          'and held in escrow for "${milestone.description}" until you '
          'release it.',
      actionLabel: 'Fund',
    );
    if (confirmed != true || !mounted) return;
    // Funding debits the requestor's wallet, so refresh the profile after.
    await _run(
      milestone,
      () => repo.fundMilestone(milestone.jobId, milestone.id),
      step: 'milestone.fund',
      refreshBalance: true,
    );
  }

  Future<void> _deliver(Milestone milestone) async {
    final repo = context.read<MilestoneRepository>();
    final note = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mark as delivered?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'The client will be asked to review the work and release '
              'the payment.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: note,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'Delivery note (optional)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Mark Delivered'),
          ),
        ],
      ),
    );
    final text = note.text.trim();
    note.dispose();
    if (confirmed != true || !mounted) return;
    await _run(
      milestone,
      () => repo.submitMilestone(
        milestone.jobId,
        milestone.id,
        note: text.isEmpty ? null : text,
      ),
      step: 'milestone.deliver',
    );
  }

  Future<void> _release(Milestone milestone) async {
    final repo = context.read<MilestoneRepository>();
    final confirmed = await _confirm(
      title: 'Release payment?',
      body:
          '${formatRm(milestone.amountSen)} will be paid to '
          '${widget.job.acceptedProviderName ?? 'the provider'} for '
          '"${milestone.description}". This cannot be undone.',
      actionLabel: 'Release',
    );
    if (confirmed != true || !mounted) return;
    // A release may complete the job (last milestone) — the job stream on
    // the detail screen picks that up on its own.
    await _run(
      milestone,
      () => repo.releaseMilestone(milestone.jobId, milestone.id),
      step: 'milestone.release',
    );
  }

  Future<void> _dispute(Milestone milestone) async {
    final raised = await RaiseDisputeSheet.show(context, milestone: milestone);
    if (raised == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Dispute submitted. An admin will review it and '
            'decide on the escrowed payment.',
          ),
        ),
      );
    }
  }

  /// Requestor approves the proposed plan, making every milestone fundable.
  Future<void> _approvePlan() async {
    final repo = context.read<MilestoneRepository>();
    final confirmed = await _confirm(
      title: 'Approve this plan?',
      body:
          'You\'ll then fund each milestone into escrow and release payment '
          'as the work is approved.',
      actionLabel: 'Approve',
    );
    if (confirmed != true || !mounted) return;
    await _runPlan(() => repo.approveMilestonePlan(widget.job.id));
  }

  /// Requestor sends the proposed plan back to the provider with a note.
  Future<void> _rejectPlan() async {
    final repo = context.read<MilestoneRepository>();
    final note = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Request changes?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('The provider will be asked to revise the plan.'),
            const SizedBox(height: 12),
            TextField(
              controller: note,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'What should change?',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Request Changes'),
          ),
        ],
      ),
    );
    final text = note.text.trim();
    note.dispose();
    if (confirmed != true || !mounted) return;
    await _runPlan(
      () => repo.rejectMilestonePlan(
        widget.job.id,
        note: text.isEmpty ? null : text,
      ),
    );
  }

  /// Provider revises the plan (opens the propose sheet pre-filled).
  Future<void> _amendPlan(List<Milestone> milestones) async {
    final changed = await ProposeMilestonesSheet.show(
      context,
      job: widget.job,
      existing: milestones,
    );
    if (changed == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Updated plan sent to the client for approval.'),
        ),
      );
    }
  }

  /// Runs a plan-level [action] (approve/reject) with a busy sentinel keyed to
  /// the section, surfacing the Cloud Function's message on failure.
  Future<void> _runPlan(Future<void> Function() action) async {
    setState(() => _busyId = _planBusyKey);
    try {
      await action();
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
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String body,
    required String actionLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }

  /// Runs a milestone [action] while its card shows a spinner, surfacing the
  /// Cloud Function's user-readable message on failure. [step] names the
  /// action for diagnostic logging (e.g. `'milestone.fund'`).
  Future<void> _run(
    Milestone milestone,
    Future<void> Function() action, {
    required String step,
    bool refreshBalance = false,
  }) async {
    setState(() => _busyId = milestone.id);
    logPayment(
      '$step.requested',
      data: {
        'jobId': milestone.jobId,
        'milestoneId': milestone.id,
        'amountSen': milestone.amountSen,
      },
    );
    try {
      await action();
      logPayment(
        '$step.result',
        data: {'milestoneId': milestone.id, 'outcome': 'ok'},
      );
      if (!mounted) return;
      if (refreshBalance) await context.read<AuthController>().refreshUser();
    } on FirebaseFunctionsException catch (e, st) {
      logPayment(
        '$step.error',
        data: {'milestoneId': milestone.id, 'code': e.code},
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      var message = e.message ?? 'Something went wrong. Please try again.';
      final insufficientBalance = message.startsWith('Insufficient');
      if (insufficientBalance) {
        message =
            '$message Top up your wallet from Profile → My Wallet, '
            'then try again.';
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          action: insufficientBalance
              ? SnackBarAction(
                  label: 'Top Up',
                  onPressed: () => context.push('/profile/earnings'),
                )
              : null,
        ),
      );
    } catch (e, st) {
      logPayment(
        '$step.error',
        data: {'milestoneId': milestone.id},
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Something went wrong. Please try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  /// The one action the viewer can take on [milestone] right now, or null.
  (String, Future<void> Function())? _actionFor(
    Milestone milestone, {
    required bool isRequestor,
    required bool isProvider,
  }) {
    return switch (milestone.status) {
      MilestoneStatus.pending when isRequestor => (
        'Fund Milestone',
        () => _fund(milestone),
      ),
      MilestoneStatus.funded when isProvider => (
        'Mark as Delivered',
        () => _deliver(milestone),
      ),
      MilestoneStatus.submitted when isRequestor => (
        'Release Payment',
        () => _release(milestone),
      ),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final myUid = context.read<AuthController>().user?.uid;
    final isRequestor = myUid == job.requestorId;
    final isProvider =
        job.acceptedProviderId != null && myUid == job.acceptedProviderId;

    // Milestones only exist between assignment and completion; other viewers
    // (e.g. losing bidders) have nothing to see here.
    if ((!isRequestor && !isProvider) ||
        (job.status != JobStatus.inProgress &&
            job.status != JobStatus.completed)) {
      return const SizedBox.shrink();
    }

    return StreamBuilder<List<Milestone>>(
      stream: _milestones,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
          );
        }
        if (snapshot.hasError) {
          return const AppCard(
            child: EmptyState(
              icon: Icons.error_outline,
              title: "Couldn't load milestones",
              message: 'Please check your connection and try again.',
            ),
          );
        }
        final milestones = [...snapshot.data ?? <Milestone>[]]
          ..sort((a, b) => a.order.compareTo(b.order));
        return _buildTracker(
          context,
          job,
          milestones,
          isRequestor: isRequestor,
          isProvider: isProvider,
        );
      },
    );
  }

  bool _planApproved(List<Milestone> milestones) =>
      milestones.isNotEmpty &&
      !milestones.any((m) => m.status == MilestoneStatus.proposed);

  /// `'plan'`, a milestone id, or `'complete'` — the step that's dominant
  /// right now. See the class doc for the rule.
  String _currentStepId(List<Milestone> milestones, bool planApproved) {
    if (!planApproved) return 'plan';
    final disputed = milestones.where(
      (m) => m.status == MilestoneStatus.disputed,
    );
    if (disputed.isNotEmpty) return disputed.first.id;
    final next = milestones.cast<Milestone?>().firstWhere(
      (m) => !_isTerminal(m!.status),
      orElse: () => null,
    );
    return next?.id ?? 'complete';
  }

  Widget _buildTracker(
    BuildContext context,
    Job job,
    List<Milestone> milestones, {
    required bool isRequestor,
    required bool isProvider,
  }) {
    final theme = Theme.of(context);
    final planApproved = _planApproved(milestones);
    // The provider may revise the plan only while nothing is funded yet.
    final planEditable =
        job.status == JobStatus.inProgress &&
        milestones.every(
          (m) =>
              m.status == MilestoneStatus.proposed ||
              m.status == MilestoneStatus.pending,
        );
    final currentId = _currentStepId(milestones, planApproved);

    final rows = <Widget>[];
    var previousDone = false;

    final planExpanded = !planApproved || _expandedOverride == 'plan';
    rows.add(
      _stepRow(
        gutter: _gutter(
          context: context,
          state: planApproved ? _CircleState.done : _CircleState.upcoming,
          topVisible: false,
          bottomVisible: true,
          topDone: false,
          bottomDone: planApproved,
        ),
        content: _planStepContent(
          context,
          job,
          milestones,
          isRequestor: isRequestor,
          isProvider: isProvider,
          expanded: planExpanded,
          planApproved: planApproved,
          planEditable: planEditable,
        ),
      ),
    );
    previousDone = planApproved;

    for (final (i, m) in milestones.indexed) {
      final isCurrent = currentId == m.id;
      final done = _isTerminal(m.status);
      final expanded = isCurrent || _expandedOverride == m.id;
      rows.add(
        _stepRow(
          gutter: _gutter(
            context: context,
            state: _circleStateFor(m.status),
            topVisible: true,
            bottomVisible: true,
            topDone: previousDone,
            bottomDone: done,
          ),
          content: _milestoneStepContent(
            context,
            job,
            m,
            index: i + 1,
            totalMilestones: milestones.length,
            isRequestor: isRequestor,
            isProvider: isProvider,
            expanded: expanded,
          ),
        ),
      );
      previousDone = done;
    }

    final jobComplete = job.status == JobStatus.completed;
    rows.add(
      _stepRow(
        gutter: _gutter(
          context: context,
          state: jobComplete ? _CircleState.done : _CircleState.upcoming,
          topVisible: true,
          bottomVisible: false,
          topDone: previousDone,
          bottomDone: false,
        ),
        content: _completeStepContent(context, done: jobComplete),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Payment & progress', style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        if (milestones.isNotEmpty) ...[
          _PlanSummaryCard(milestones: milestones),
          const SizedBox(height: 16),
        ],
        ...rows,
      ],
    );
  }

  Widget _planStepContent(
    BuildContext context,
    Job job,
    List<Milestone> milestones, {
    required bool isRequestor,
    required bool isProvider,
    required bool expanded,
    required bool planApproved,
    required bool planEditable,
  }) {
    final theme = Theme.of(context);
    final totalSen = milestones.fold<int>(0, (s, m) => s + m.amountSen);

    if (!expanded) {
      return Semantics(
        button: true,
        label:
            'Step 1, Agree the plan, approved, ${milestones.length} '
            'milestones, ${formatRm(totalSen)} total.',
        child: InkWell(
          onTap: () => _toggleExpand('plan'),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Plan agreed, ${milestones.length} '
                    'milestone${milestones.length == 1 ? '' : 's'}, '
                    '${formatRm(totalSen)}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (isProvider && planEditable)
                  TextButton(
                    onPressed: _busyId == _planBusyKey
                        ? null
                        : () => _amendPlan(milestones),
                    child: const Text('Amend'),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    final busy = _busyId == _planBusyKey;
    late final Widget body;
    if (milestones.isEmpty) {
      body = isProvider
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (job.planRejectionNote != null) ...[
                  Text(
                    'The client asked for changes: '
                    '"${job.planRejectionNote}"',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: context.fairbid.danger,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                Text(
                  'Split the accepted '
                  '${formatRm(job.acceptedBidAmountSen ?? 0)} into '
                  'milestones. The client approves the plan, then funds '
                  'each one into escrow before you start, releasing '
                  'payment as work is approved.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                PrimaryButton(
                  label: 'Propose Milestones',
                  onPressed: () =>
                      ProposeMilestonesSheet.show(context, job: job),
                ),
              ],
            )
          : Text(
              "Waiting for the provider to propose a milestone plan. "
              "You'll fund each milestone into escrow and release payment "
              'as work is approved.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            );
    } else {
      body = isRequestor
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The provider proposed how to split the accepted bid. '
                  'Approve it to start funding, or ask for changes.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                PrimaryButton(
                  label: 'Approve Plan',
                  busy: busy,
                  onPressed: _approvePlan,
                ),
                const SizedBox(height: 8),
                SecondaryButton(
                  label: 'Request Changes',
                  onPressed: busy ? null : _rejectPlan,
                ),
              ],
            )
          : Text(
              "The client is reviewing your proposed plan. They'll fund "
              'the first milestone once they approve it.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            );
    }

    return Semantics(
      label:
          'Step 1, Agree the plan, '
          '${milestones.isEmpty ? 'awaiting proposal' : 'awaiting approval'}.',
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: context.fairbid.subtleBlue,
          borderRadius: BorderRadius.circular(12),
          border: Border(
            left: BorderSide(color: context.fairbid.verified, width: 3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Agree the plan', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            body,
          ],
        ),
      ),
    );
  }

  Widget _milestoneStepContent(
    BuildContext context,
    Job job,
    Milestone m, {
    required int index,
    required int totalMilestones,
    required bool isRequestor,
    required bool isProvider,
    required bool expanded,
  }) {
    final theme = Theme.of(context);
    final busy = _busyId == m.id;
    final stepNumber = index + 1; // Step 0 (the plan) is step 1.
    final totalSteps = totalMilestones + 2; // + plan + job complete.
    final turnDescriptor = m.status == MilestoneStatus.disputed
        ? 'an admin is reviewing'
        : _myTurn(m.status, isRequestor: isRequestor)
        ? 'waiting on you'
        : 'waiting on ${_counterpartyName(job, isRequestor: isRequestor)}';
    final semanticsLabel =
        'Step $stepNumber of $totalSteps, '
        '${m.description}, ${formatRm(m.amountSen)}, ${m.status.label}, '
        '$turnDescriptor.';

    if (!expanded) {
      return Semantics(
        button: true,
        label: semanticsLabel,
        child: InkWell(
          onTap: () => _toggleExpand(m.id),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              '$index. ${_collapsedLine(m)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    final action = _actionFor(
      m,
      isRequestor: isRequestor,
      isProvider: isProvider,
    );
    final canDispute =
        m.status == MilestoneStatus.funded ||
        m.status == MilestoneStatus.submitted;
    final disputed = m.status == MilestoneStatus.disputed;
    final mine = _myTurn(m.status, isRequestor: isRequestor);
    final accent = _statusAccent(context, m.status);

    // `Border` can't mix a coloured left accent with a differently-coloured
    // frame and a borderRadius in one go (Flutter's non-uniform-border paint
    // path only supports a single visible colour) — so the accent is a
    // separate opaque strip inside a uniformly-bordered, clipped box instead
    // of one four-sided Border.
    return Semantics(
      label: semanticsLabel,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: context.fairbid.borderSubtle),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 3, color: accent),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              '$index. ${m.description}',
                              style: theme.textTheme.bodyLarge,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: PillBadge(
                              label: m.status.label,
                              icon: _statusIcon(m.status),
                              color: accent,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          Text(
                            formatRm(m.amountSen),
                            style: theme.textTheme.titleLarge?.copyWith(
                              color: context.fairbid.verified,
                            ),
                          ),
                          if (disputed)
                            const _TurnPill.admin()
                          else
                            _TurnPill(
                              mine: mine,
                              label: mine
                                  ? 'Your turn'
                                  : 'Waiting on '
                                        '${_counterpartyName(job, isRequestor: isRequestor)}',
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _statusLine(job, m),
                        style: theme.textTheme.bodyMedium,
                      ),
                      if (m.reworkNote != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: context.fairbid.danger.withValues(
                              alpha: 0.08,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'Sent back for rework: ${m.reworkNote}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: context.fairbid.danger,
                            ),
                          ),
                        ),
                      ],
                      if (m.submissionNote != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Delivery note: ${m.submissionNote}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      if (disputed)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.hourglass_empty,
                              size: 16,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Frozen while a FairBid admin reviews this milestone.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        )
                      else
                        _MicroProgress(status: m.status),
                      if (action != null) ...[
                        const SizedBox(height: 12),
                        PrimaryButton(
                          label: action.$1,
                          busy: busy,
                          onPressed: () => action.$2(),
                        ),
                      ],
                      if (canDispute) ...[
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: busy ? null : () => _dispute(m),
                            style: TextButton.styleFrom(
                              foregroundColor:
                                  theme.colorScheme.onSurfaceVariant,
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(0, 32),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text('Something wrong?'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _completeStepContent(BuildContext context, {required bool done}) {
    final theme = Theme.of(context);
    return Semantics(
      label: done ? 'Job complete.' : 'Job complete, not reached yet.',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          'Job complete',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: done
                ? theme.colorScheme.onSurface
                : theme.colorScheme.onSurfaceVariant,
            fontWeight: done ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  /// Whether it's [isRequestor]'s (vs. the provider's) move on [status].
  bool _myTurn(MilestoneStatus status, {required bool isRequestor}) =>
      switch (status) {
        MilestoneStatus.pending || MilestoneStatus.submitted => isRequestor,
        MilestoneStatus.funded => !isRequestor,
        _ => false,
      };

  String _counterpartyName(Job job, {required bool isRequestor}) => isRequestor
      ? (job.acceptedProviderName ?? 'the provider')
      : job.requestorName;

  /// The plain-language money line for the expanded (current) step, per the
  /// per-milestone micro-progression table.
  String _statusLine(Job job, Milestone m) {
    final amount = formatRm(m.amountSen);
    final provider = job.acceptedProviderName ?? 'the provider';
    return switch (m.status) {
      MilestoneStatus.pending => 'Fund $amount to start this milestone.',
      MilestoneStatus.funded => '$amount held in escrow, $provider is working.',
      MilestoneStatus.submitted => 'Delivered, review and release $amount.',
      MilestoneStatus.released => 'Paid out.',
      MilestoneStatus.disputed => 'On hold, an admin is reviewing.',
      MilestoneStatus.proposed => 'Awaiting client approval.',
      MilestoneStatus.resolved => 'Resolved.',
    };
  }

  /// The collapsed one-line summary for a done or upcoming milestone step.
  String _collapsedLine(Milestone m) {
    final amount = formatRm(m.amountSen);
    return switch (m.status) {
      MilestoneStatus.released => '${m.description}, $amount paid out',
      MilestoneStatus.resolved => '${m.description}, $amount resolved',
      MilestoneStatus.pending => '${m.description}, $amount, not funded yet',
      MilestoneStatus.funded => '${m.description}, $amount, in escrow',
      MilestoneStatus.submitted =>
        '${m.description}, $amount, delivered, awaiting release',
      MilestoneStatus.disputed => '${m.description}, $amount, disputed',
      MilestoneStatus.proposed => '${m.description}, $amount',
    };
  }
}

/// Gutter circle shape per state (WCAG 1.4.1: shape carries the state, not
/// just colour) — filled-with-check (done), ring-with-lock (in escrow),
/// hollow (upcoming), filled-with-`!` (disputed).
enum _CircleState { done, inEscrow, upcoming, disputed }

_CircleState _circleStateFor(MilestoneStatus s) => switch (s) {
  MilestoneStatus.released || MilestoneStatus.resolved => _CircleState.done,
  MilestoneStatus.funded || MilestoneStatus.submitted => _CircleState.inEscrow,
  MilestoneStatus.disputed => _CircleState.disputed,
  MilestoneStatus.proposed || MilestoneStatus.pending => _CircleState.upcoming,
};

/// Status-chip colour per state — [FairBidColors.warningText] (not the raw
/// `warning` fill) so the pill's text/icon keeps readable contrast.
Color _statusAccent(BuildContext context, MilestoneStatus s) => switch (s) {
  MilestoneStatus.proposed ||
  MilestoneStatus.pending ||
  MilestoneStatus.submitted => context.fairbid.warningText,
  MilestoneStatus.funded => context.fairbid.verified,
  MilestoneStatus.released => context.fairbid.success,
  MilestoneStatus.disputed => context.fairbid.danger,
  MilestoneStatus.resolved => Theme.of(context).colorScheme.onSurfaceVariant,
};

IconData _statusIcon(MilestoneStatus s) => switch (s) {
  MilestoneStatus.proposed || MilestoneStatus.pending => Icons.hourglass_empty,
  MilestoneStatus.funded => Icons.lock_outline,
  MilestoneStatus.submitted => Icons.inventory_2_outlined,
  MilestoneStatus.released => Icons.check_circle_outline,
  MilestoneStatus.disputed => Icons.gavel_rounded,
  MilestoneStatus.resolved => Icons.info_outline,
};

/// One `Row(children: [SizedBox(width: 32, child: gutter), Expanded(content)])`
/// tracker row. Wrapped in [IntrinsicHeight] so the gutter's connector lines
/// (which need a bounded height to flex against) can stretch to match
/// whatever height [content] ends up needing that build.
Widget _stepRow({required Widget gutter, required Widget content}) {
  return IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 32, child: gutter),
        const SizedBox(width: 12),
        Expanded(child: content),
      ],
    ),
  );
}

/// The gutter: a 2dp connector line above and below a 24dp state circle.
/// [topVisible]/[bottomVisible] hide the line for the tracker's first/last
/// step; otherwise the segment is coloured when the step it touches is done.
Widget _gutter({
  required BuildContext context,
  required _CircleState state,
  required bool topVisible,
  required bool bottomVisible,
  required bool topDone,
  required bool bottomDone,
}) {
  final theme = Theme.of(context);
  Color line(bool done) =>
      done ? context.fairbid.verified : theme.colorScheme.outlineVariant;
  return Column(
    children: [
      Expanded(
        child: Container(
          width: 2,
          color: topVisible ? line(topDone) : Colors.transparent,
        ),
      ),
      _StepCircle(state: state),
      Expanded(
        child: Container(
          width: 2,
          color: bottomVisible ? line(bottomDone) : Colors.transparent,
        ),
      ),
    ],
  );
}

class _StepCircle extends StatelessWidget {
  const _StepCircle({required this.state});
  final _CircleState state;

  @override
  Widget build(BuildContext context) {
    final fairbid = context.fairbid;
    final theme = Theme.of(context);
    return switch (state) {
      _CircleState.done => _circle(
        fill: fairbid.success,
        icon: Icons.check,
        iconColor: Colors.white,
      ),
      _CircleState.disputed => _circle(
        fill: fairbid.danger,
        icon: Icons.priority_high,
        iconColor: Colors.white,
      ),
      _CircleState.inEscrow => _ring(
        border: fairbid.verified,
        icon: Icons.lock_outline,
        iconColor: fairbid.verified,
      ),
      _CircleState.upcoming => _ring(border: theme.colorScheme.outlineVariant),
    };
  }

  Widget _circle({
    required Color fill,
    required IconData icon,
    required Color iconColor,
  }) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
      child: Icon(icon, size: 14, color: iconColor),
    );
  }

  Widget _ring({required Color border, IconData? icon, Color? iconColor}) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        border: Border.all(color: border, width: 2),
      ),
      child: icon == null ? null : Icon(icon, size: 12, color: iconColor),
    );
  }
}

/// "Your turn" (accent-filled) vs "Waiting on {name}" (neutral outline) —
/// the highest-value single addition to the tracker: whoever is looking
/// immediately knows if the ball is in their court.
class _TurnPill extends StatelessWidget {
  const _TurnPill({required this.mine, required this.label})
    : _adminCopy = null;
  const _TurnPill.admin()
    : mine = false,
      label = '',
      _adminCopy = 'With a FairBid admin';

  final bool mine;
  final String label;
  final String? _adminCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = _adminCopy ?? label;
    if (mine) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: context.fairbid.verified,
          borderRadius: BorderRadius.circular(9999),
        ),
        child: Text(
          text,
          style: theme.textTheme.labelMedium?.copyWith(color: Colors.white),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9999),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The three small labelled beats (Fund → Deliver → Release) for the
/// expanded current step, so the status reads as a position in a sequence
/// rather than an opaque word.
class _MicroProgress extends StatelessWidget {
  const _MicroProgress({required this.status});
  final MilestoneStatus status;

  static const _labels = ['Fund', 'Deliver', 'Release'];

  int get _activeIndex => switch (status) {
    MilestoneStatus.proposed || MilestoneStatus.pending => 0,
    MilestoneStatus.funded => 1,
    MilestoneStatus.submitted => 2,
    MilestoneStatus.released || MilestoneStatus.resolved => 3,
    MilestoneStatus.disputed => -1,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = context.fairbid.verified;
    final active = _activeIndex;
    return Row(
      children: [
        for (final (i, label) in _labels.indexed) ...[
          if (i != 0)
            Expanded(
              child: Container(
                height: 2,
                color: i <= active ? accent : context.fairbid.borderSubtle,
              ),
            ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i <= active ? accent : Colors.white,
                  border: i <= active
                      ? null
                      : Border.all(
                          color: context.fairbid.borderSubtle,
                          width: 2,
                        ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: i <= active
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: i == active ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// The card above the tracker: total, a segmented Paid out / In escrow / Not
/// funded bar (word + icon per segment, never colour alone), and a plain-
/// language reassurance for first-time requestors.
class _PlanSummaryCard extends StatelessWidget {
  const _PlanSummaryCard({required this.milestones});
  final List<Milestone> milestones;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalSen = milestones.fold<int>(0, (s, m) => s + m.amountSen);
    final paidOutSen = milestones
        .where(
          (m) =>
              m.status == MilestoneStatus.released ||
              m.status == MilestoneStatus.resolved,
        )
        .fold<int>(0, (s, m) => s + m.amountSen);
    final inEscrowSen = milestones
        .where(
          (m) =>
              m.status == MilestoneStatus.funded ||
              m.status == MilestoneStatus.submitted ||
              m.status == MilestoneStatus.disputed,
        )
        .fold<int>(0, (s, m) => s + m.amountSen);
    final notFundedSen = totalSen - paidOutSen - inEscrowSen;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Total plan', style: theme.textTheme.labelMedium),
              ),
              Text(formatRm(totalSen), style: theme.textTheme.titleLarge),
            ],
          ),
          const SizedBox(height: 12),
          if (totalSen > 0)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Row(
                children: [
                  if (paidOutSen > 0)
                    Expanded(
                      flex: paidOutSen,
                      child: Container(
                        height: 8,
                        color: context.fairbid.success,
                      ),
                    ),
                  if (inEscrowSen > 0)
                    Expanded(
                      flex: inEscrowSen,
                      child: Container(
                        height: 8,
                        color: context.fairbid.verified,
                      ),
                    ),
                  if (notFundedSen > 0)
                    Expanded(
                      flex: notFundedSen,
                      child: Container(
                        height: 8,
                        color: context.fairbid.borderSubtle,
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _legend(
                context,
                icon: Icons.check_circle_outline,
                color: context.fairbid.success,
                label: 'Paid out ${formatRm(paidOutSen)}',
              ),
              _legend(
                context,
                icon: Icons.lock_outline,
                color: context.fairbid.verified,
                label: 'In escrow ${formatRm(inEscrowSen)}',
              ),
              _legend(
                context,
                icon: Icons.hourglass_empty,
                color: theme.colorScheme.onSurfaceVariant,
                label: 'Not funded ${formatRm(notFundedSen)}',
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.shield_outlined,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Money you fund is held by FairBid, not paid to the '
                  'provider, until you release it.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _legend(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String label,
  }) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
