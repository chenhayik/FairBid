import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/money.dart';
import '../../../../core/util/payment_log.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../auth/presentation/auth_controller.dart';
import '../../../disputes/data/dispute_repository.dart';
import '../../../disputes/presentation/raise_dispute_sheet.dart';
import '../../data/milestone_repository.dart';
import '../../domain/job.dart';
import '../../domain/milestone.dart';

/// What:   Escrow tracker: one step per milestone, then "Job complete".
/// Input:  Milestones via MilestoneRepository.watchMilestones() (milestone_repository.dart); [job].
/// Output: Steps with dispute/withdraw; the bottom bar runs deliver/release via [runCurrentAction].
/// How:    Only the current step (disputed first, else first unfinished) is expanded.
class MilestoneSection extends StatefulWidget {
  const MilestoneSection({super.key, required this.job, this.busy});

  final Job job;

  /// Set while an action runs, so the bottom bar shows busy too.
  final ValueNotifier<bool>? busy;

  @override
  State<MilestoneSection> createState() => MilestoneSectionState();
}

/// What:   State of [MilestoneSection]; public so the screen can reach it through a GlobalKey.
class MilestoneSectionState extends State<MilestoneSection> {
  late final Stream<List<Milestone>> _milestones = context
      .read<MilestoneRepository>()
      .watchMilestones(widget.job.id);

  String? _busyId;

  void _setBusy(String? id) {
    setState(() => _busyId = id);
    widget.busy?.value = id != null;
  }

  /// Step id (milestone id or `'complete'`) the viewer tapped open.
  String? _expandedOverride;

  List<Milestone> _latest = const [];

  /// What:   Expands or collapses a step the viewer tapped.
  /// Output: Sets [_expandedOverride]; the current step is always expanded.
  void _toggleExpand(String stepId) {
    setState(() {
      _expandedOverride = _expandedOverride == stepId ? null : stepId;
    });
  }

  /// What:   Mark-as-delivered flow (provider).
  /// Output: Warns if the visit time hasn't come yet, asks for an optional note, then MilestoneRepository.submitMilestone() via [_run].
  Future<void> _deliver(Milestone milestone) async {
    final repo = context.read<MilestoneRepository>();
    final visit = widget.job.appointment?.startAt;
    if (visit != null && visit.isAfter(DateTime.now())) {
      final early = await showConfirmDialog(
        context,
        title: 'Visit time not reached',
        body: "The visit time hasn't come yet. Mark as delivered anyway?",
        actionLabel: 'Continue',
      );
      if (!early || !mounted) return;
    }
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
            child: const Text('Mark delivered'),
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

  /// What:   Release-payment flow (requestor).
  /// Output: After a confirm dialog, MilestoneRepository.releaseMilestone() via [_run].
  Future<void> _release(Milestone milestone) async {
    final repo = context.read<MilestoneRepository>();
    final confirmed = await showConfirmDialog(
      context,
      title: 'Release payment?',
      body:
          '${formatRm(milestone.amountSen)} will be paid to '
          '${widget.job.acceptedProviderName ?? 'the provider'} for '
          '"${milestone.description}". This cannot be undone.',
      actionLabel: 'Release',
    );
    if (!confirmed || !mounted) return;
    await _run(
      milestone,
      () => repo.releaseMilestone(milestone.jobId, milestone.id),
      step: 'milestone.release',
    );
  }

  /// What:   The milestone a dispute can be raised on.
  /// Output: The first funded or submitted milestone, or null.
  Milestone? get disputableMilestone => _latest
      .where((m) =>
          m.status == MilestoneStatus.funded ||
          m.status == MilestoneStatus.submitted)
      .firstOrNull;

  /// What:   Whether any milestone is currently disputed.
  bool get hasOpenDispute =>
      _latest.any((m) => m.status == MilestoneStatus.disputed);

  /// What:   Opens the dispute sheet for [disputableMilestone].
  /// Input:  Optional [initialStatement] to pre-fill.
  Future<void> raiseDispute({String? initialStatement}) async {
    final m = disputableMilestone;
    if (m != null) await _dispute(m, initialStatement);
  }

  /// What:   Shows RaiseDisputeSheet for a milestone.
  /// Output: A snackbar once the dispute is submitted.
  Future<void> _dispute(Milestone milestone, [String? initialStatement]) async {
    final raised = await RaiseDisputeSheet.show(context,
        milestone: milestone, initialStatement: initialStatement);
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

  /// What:   Withdraw-dispute flow.
  /// Output: After a confirm dialog, DisputeRepository.withdrawDispute() via [_run]; no money moves.
  Future<void> _withdraw(Milestone milestone) async {
    final repo = context.read<DisputeRepository>();
    final confirmed = await showConfirmDialog(
      context,
      title: 'Withdraw your dispute?',
      body:
          'The admin will stop reviewing it and "${milestone.description}" '
          'goes back to where it was. No money moves.',
      actionLabel: 'Withdraw',
    );
    if (!confirmed || !mounted) return;
    await _run(
      milestone,
      () => repo.withdrawDispute(
        jobId: milestone.jobId,
        milestoneId: milestone.id,
      ),
      step: 'dispute.withdraw',
    );
  }

  /// What:   Runs one escrow action with busy state and payment logging.
  /// Input:  [milestone], the [action] to run and [step], the log key (e.g. `milestone.release`).
  /// Output: Spinner while busy, haptic feedback, and the server's message in a snackbar on failure.
  Future<void> _run(
    Milestone milestone,
    Future<void> Function() action, {
    required String step,
  }) async {
    _setBusy(milestone.id);
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
      // Not awaited: a haptic failure must not be reported as a payment failure.
      unawaited(HapticFeedback.mediumImpact());
    } on FirebaseFunctionsException catch (e, st) {
      logPayment(
        '$step.error',
        data: {'milestoneId': milestone.id, 'code': e.code},
        error: e,
        stackTrace: st,
      );
      unawaited(HapticFeedback.heavyImpact());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message ?? 'Something went wrong. Please try again.'),
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
      if (mounted) _setBusy(null);
    }
  }

  /// What:   Runs the bottom bar's deliver or release.
  /// Output: Provider on a funded step: deliver (once a visit time is agreed). Requestor on a submitted step: release. Else nothing.
  Future<void> runCurrentAction() async {
    if (_busyId != null) return;
    final job = widget.job;
    final myUid = context.read<AuthController>().user?.uid;
    final m = currentStage(_latest);
    // Delivery waits until a visit time is agreed.
    if (m?.status == MilestoneStatus.funded &&
        myUid == job.acceptedProviderId &&
        !job.needsAppointment) {
      await _deliver(m!);
    } else if (m?.status == MilestoneStatus.submitted &&
        myUid == job.requestorId) {
      await _release(m!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final myUid = context.read<AuthController>().user?.uid;
    final isRequestor = myUid == job.requestorId;
    final isProvider =
        job.acceptedProviderId != null && myUid == job.acceptedProviderId;

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
        _latest = milestones;
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

  /// What:   Id of the current step (the one always expanded).
  /// Output: currentStage() id (disputed first, else first unfinished), or `'complete'` when all are done.
  String _currentStepId(List<Milestone> milestones) {
    return currentStage(milestones)?.id ?? 'complete';
  }

  /// What:   The whole tracker.
  /// Input:  Sorted [milestones], [job] and the viewer's role flags.
  /// Output: Plan summary, one connected step row per milestone, then "Job complete".
  Widget _buildTracker(
    BuildContext context,
    Job job,
    List<Milestone> milestones, {
    required bool isRequestor,
    required bool isProvider,
  }) {
    final theme = Theme.of(context);
    final currentId = _currentStepId(milestones);

    final rows = <Widget>[];
    var previousDone = false;

    for (final (i, m) in milestones.indexed) {
      final isCurrent = currentId == m.id;
      final done = m.status.isTerminal;
      final expanded = isCurrent || _expandedOverride == m.id;
      rows.add(
        _stepRow(
          gutter: _gutter(
            context: context,
            state: _circleStateFor(m.status),
            topVisible: i > 0,
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
          _PlanSummaryCard(
            milestones: milestones,
            isProvider: isProvider,
          ),
          const SizedBox(height: 16),
        ],
        ...rows,
      ],
    );
  }

  /// What:   Content of one milestone step.
  /// Output: Collapsed one-line summary, or the expanded card with status, actions and progress.
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
    final totalSteps = totalMilestones + 1;
    final turnDescriptor = m.status == MilestoneStatus.disputed
        ? 'an admin is reviewing'
        : _myTurn(m.status, isRequestor: isRequestor)
        ? 'waiting on you'
        : 'waiting on ${_counterpartyName(job, isRequestor: isRequestor)}';
    final semanticsLabel =
        'Step $index of $totalSteps, '
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

    final canDispute =
        m.status == MilestoneStatus.funded ||
        m.status == MilestoneStatus.submitted;
    final disputed = m.status == MilestoneStatus.disputed;
    final mine = _myTurn(m.status, isRequestor: isRequestor);
    final accent = _statusAccent(context, m.status);

    // Accent is a strip, not a Border side: Flutter can't paint mixed colours with a radius.
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
                      Text(
                        '$index. ${m.description}',
                        style: theme.textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 8),
                      // Own line so large text scales don't truncate it.
                      Align(
                        alignment: Alignment.centerLeft,
                        child: PillBadge(
                          label: m.status.label,
                          icon: _statusIcon(m.status),
                          color: accent,
                        ),
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
                          _TurnPill(
                            mine: mine,
                            label: disputed
                                ? 'With a FairBid admin'
                                : mine
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
                      if (busy) ...[
                        const SizedBox(height: 12),
                        const LinearProgressIndicator(),
                      ],
                      if (canDispute) ...[
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton.icon(
                            onPressed: busy ? null : () => _dispute(m),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: context.fairbid.danger,
                              side: BorderSide(color: context.fairbid.danger),
                            ),
                            icon: const Icon(Icons.gavel_rounded, size: 18),
                            label: const Text('Raise a dispute'),
                          ),
                        ),
                      ],
                      if (disputed &&
                          m.disputedBy != null &&
                          m.disputedBy ==
                              context.read<AuthController>().user?.uid) ...[
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: busy ? null : () => _withdraw(m),
                            icon: const Icon(Icons.undo, size: 18),
                            label: const Text('Withdraw dispute'),
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

  /// What:   The final "Job complete" step.
  /// Output: Label, emphasised once [done].
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

  /// What:   Whether the viewer must act on a milestone.
  /// Output: True for the requestor on submitted (release) and the provider on funded (deliver).
  bool _myTurn(MilestoneStatus status, {required bool isRequestor}) =>
      switch (status) {
        MilestoneStatus.submitted => isRequestor,
        MilestoneStatus.funded => !isRequestor,
        _ => false,
      };

  /// What:   Name of the other party.
  /// Output: The provider's name for the requestor, else the requestor's.
  String _counterpartyName(Job job, {required bool isRequestor}) => isRequestor
      ? (job.acceptedProviderName ?? 'the provider')
      : job.requestorName;

  /// What:   Status sentence for an expanded step.
  /// Output: Text such as "RM 100 secured in escrow, Ali is working." chosen by milestone status.
  String _statusLine(Job job, Milestone m) {
    final amount = formatRm(m.amountSen);
    final provider = job.acceptedProviderName ?? 'the provider';
    return switch (m.status) {
      MilestoneStatus.funded when job.needsAppointment =>
        '$amount secured in escrow. Agree a visit time first.',
      MilestoneStatus.funded =>
        '$amount secured in escrow, $provider is working.',
      MilestoneStatus.submitted => 'Delivered, review and release $amount.',
      MilestoneStatus.released => 'Paid out.',
      MilestoneStatus.disputed => 'On hold, an admin is reviewing.',
      MilestoneStatus.proposed || MilestoneStatus.pending => 'Not funded.',
      MilestoneStatus.resolved => 'Resolved.',
      MilestoneStatus.refunded => '$amount went back to the client.',
    };
  }

  /// What:   One-line summary for a collapsed step.
  /// Output: Description, amount and status.
  String _collapsedLine(Milestone m) {
    final amount = formatRm(m.amountSen);
    return switch (m.status) {
      MilestoneStatus.released => '${m.description}, $amount paid out',
      MilestoneStatus.resolved => '${m.description}, $amount resolved',
      MilestoneStatus.funded => '${m.description}, $amount, in escrow',
      MilestoneStatus.submitted =>
        '${m.description}, $amount, delivered, awaiting release',
      MilestoneStatus.disputed => '${m.description}, $amount, disputed',
      MilestoneStatus.proposed ||
      MilestoneStatus.pending => '${m.description}, $amount, not funded',
      MilestoneStatus.refunded => '${m.description}, $amount refunded',
    };
  }
}

/// What:   Circle shape per step state, so shape (not just colour) carries the state.
/// Input:  Mapped from MilestoneStatus by [_circleStateFor].
/// Output: done, inEscrow, upcoming or disputed.
enum _CircleState { done, inEscrow, upcoming, disputed }

/// What:   Maps a milestone status to its circle state.
_CircleState _circleStateFor(MilestoneStatus s) => switch (s) {
  MilestoneStatus.released ||
  MilestoneStatus.resolved ||
  MilestoneStatus.refunded => _CircleState.done,
  MilestoneStatus.funded || MilestoneStatus.submitted => _CircleState.inEscrow,
  MilestoneStatus.disputed => _CircleState.disputed,
  MilestoneStatus.proposed || MilestoneStatus.pending => _CircleState.upcoming,
};

/// What:   Accent colour for a milestone status.
Color _statusAccent(BuildContext context, MilestoneStatus s) => switch (s) {
  MilestoneStatus.proposed ||
  MilestoneStatus.pending ||
  MilestoneStatus.submitted => context.fairbid.warningText,
  MilestoneStatus.funded => context.fairbid.verified,
  MilestoneStatus.released => context.fairbid.successText,
  MilestoneStatus.disputed => context.fairbid.danger,
  MilestoneStatus.resolved ||
  MilestoneStatus.refunded => Theme.of(context).colorScheme.onSurfaceVariant,
};

/// What:   Icon for a milestone status.
IconData _statusIcon(MilestoneStatus s) => switch (s) {
  MilestoneStatus.proposed || MilestoneStatus.pending => Icons.hourglass_empty,
  MilestoneStatus.funded => Icons.lock_outline,
  MilestoneStatus.submitted => Icons.inventory_2_outlined,
  MilestoneStatus.released => Icons.check_circle_outline,
  MilestoneStatus.disputed => Icons.gavel_rounded,
  MilestoneStatus.resolved => Icons.info_outline,
  MilestoneStatus.refunded => Icons.undo,
};

/// What:   One tracker row: gutter beside content.
/// Notes:  IntrinsicHeight lets the gutter's connector lines stretch to the content.
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

/// What:   The connector line above and below a state circle.
/// Output: Hidden at the first and last step; green once the adjacent step is done.
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

/// What:   The state circle in the gutter.
/// Input:  [state].
/// Output: Filled tick (done), filled exclamation (disputed), lock ring (in escrow) or empty ring (upcoming).
class _StepCircle extends StatelessWidget {
  const _StepCircle({required this.state});
  final _CircleState state;

  @override
  Widget build(BuildContext context) {
    final fairbid = context.fairbid;
    final theme = Theme.of(context);
    return switch (state) {
      // successText, not success: a white tick on the brighter fill has poor contrast.
      _CircleState.done => _circle(
        fill: fairbid.successText,
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

/// What:   Whose-turn pill.
/// Input:  [mine] and [label].
/// Output: Filled "Your turn" when mine, else outlined "Waiting on ...".
class _TurnPill extends StatelessWidget {
  const _TurnPill({required this.mine, required this.label});

  final bool mine;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: mine ? context.fairbid.verified : null,
        borderRadius: BorderRadius.circular(9999),
        border: mine
            ? null
            : Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: mine ? Colors.white : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// What:   Fund, Deliver, Release progress dots for the expanded step.
/// Input:  [status].
/// Output: Dots up to the active beat; none active for disputed or refunded.
class _MicroProgress extends StatelessWidget {
  const _MicroProgress({required this.status});
  final MilestoneStatus status;

  static const _labels = ['Fund', 'Deliver', 'Release'];

  int get _activeIndex => switch (status) {
    MilestoneStatus.proposed || MilestoneStatus.pending => 0,
    MilestoneStatus.funded => 1,
    MilestoneStatus.submitted => 2,
    MilestoneStatus.released || MilestoneStatus.resolved => 3,
    MilestoneStatus.disputed || MilestoneStatus.refunded => -1,
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

/// What:   Summary above the tracker: price, Paid out / In escrow / Not funded bar, reassurance.
/// Input:  [milestones] from MilestoneSectionState; [isProvider] picks the wording.
/// Output: AppCard; each segment has a word and icon, not colour alone.
class _PlanSummaryCard extends StatelessWidget {
  const _PlanSummaryCard({
    required this.milestones,
    required this.isProvider,
  });
  final List<Milestone> milestones;
  final bool isProvider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    int sum(bool Function(MilestoneStatus s) test) => milestones
        .where((m) => test(m.status))
        .fold<int>(0, (s, m) => s + m.amountSen);
    final totalSen = sum((_) => true);
    final paidOutSen = sum(
      (s) => s == MilestoneStatus.released || s == MilestoneStatus.resolved,
    );
    final inEscrowSen = sum(
      (s) =>
          s == MilestoneStatus.funded ||
          s == MilestoneStatus.submitted ||
          s == MilestoneStatus.disputed,
    );
    final refundedSen = sum((s) => s == MilestoneStatus.refunded);
    final notFundedSen = totalSen - paidOutSen - inEscrowSen - refundedSen;
    final segments = [
      (paidOutSen, context.fairbid.success),
      (inEscrowSen, context.fairbid.verified),
      (refundedSen, theme.colorScheme.onSurfaceVariant),
      (notFundedSen, context.fairbid.borderSubtle),
    ];

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Job price',
                    style: theme.textTheme.labelMedium),
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
                  for (final (sen, color) in segments)
                    if (sen > 0)
                      Expanded(
                        flex: sen,
                        child: Container(height: 8, color: color),
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
                color: context.fairbid.successText,
                label: 'Paid out ${formatRm(paidOutSen)}',
              ),
              _legend(
                context,
                icon: Icons.lock_outline,
                color: context.fairbid.verified,
                label: 'In escrow ${formatRm(inEscrowSen)}',
              ),
              if (refundedSen > 0)
                _legend(
                  context,
                  icon: Icons.undo,
                  color: theme.colorScheme.onSurfaceVariant,
                  label: 'Refunded ${formatRm(refundedSen)}',
                ),
              if (notFundedSen > 0)
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
                  isProvider
                      ? 'The full price is held in escrow and paid to you '
                            'when the client approves the work.'
                      : 'Your payment is held in escrow, not paid to the '
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
