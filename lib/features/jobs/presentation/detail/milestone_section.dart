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

/// The escrow stages on a job detail: a hand-rolled vertical progress
/// tracker (never Flutter's `Stepper` - it owns its own scroll physics and its
/// fixed `StepState` can't express funded/submitted/released/disputed). One
/// linear sequence: one step per stage, then a terminal "Job complete" step.
/// The job is funded at award, so per stage the provider delivers and the
/// requestor releases payment. Releasing the last stage completes the job
/// (server-side, via the `releaseMilestone` Cloud Function), which is what
/// unlocks reviews.
///
/// Only the *current* step - the first stage not yet released, or any
/// disputed stage regardless of position - renders expanded. Every other step
/// collapses to one muted line; tapping a collapsed step expands it. The
/// screen's bottom bar owns the primary action (deliver, release) and
/// triggers it through [runCurrentAction]; the section only keeps the
/// secondary ones (dispute, withdraw).
class MilestoneSection extends StatefulWidget {
  const MilestoneSection({super.key, required this.job, this.busy});

  final Job job;

  /// Mirrors "an action is running", so the bottom bar can show busy too.
  final ValueNotifier<bool>? busy;

  @override
  State<MilestoneSection> createState() => MilestoneSectionState();
}

/// Terminal statuses: money has finished moving for this milestone (paid
/// out, or the legacy `resolved` alias - see [MilestoneStatus]'s doc).
bool _isTerminal(MilestoneStatus s) =>
    s == MilestoneStatus.released ||
    s == MilestoneStatus.resolved ||
    s == MilestoneStatus.refunded;

class MilestoneSectionState extends State<MilestoneSection> {
  // Cached so rebuilds don't resubscribe to Firestore.
  late final Stream<List<Milestone>> _milestones = context
      .read<MilestoneRepository>()
      .watchMilestones(widget.job.id);

  /// The milestone with an action call in flight, disabling its button.
  String? _busyId;

  void _setBusy(String? id) {
    setState(() => _busyId = id);
    widget.busy?.value = id != null;
  }

  /// The step (keyed by a milestone id or `'complete'`) the
  /// viewer tapped open manually. The current step is always expanded
  /// regardless of this.
  String? _expandedOverride;

  /// The latest milestones, sorted by order, for [runCurrentAction].
  List<Milestone> _latest = const [];

  void _toggleExpand(String stepId) {
    setState(() {
      _expandedOverride = _expandedOverride == stepId ? null : stepId;
    });
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
    // A release may complete the job (last milestone) - the job stream on
    // the detail screen picks that up on its own.
    await _run(
      milestone,
      () => repo.releaseMilestone(milestone.jobId, milestone.id),
      step: 'milestone.release',
    );
  }

  /// The paid milestone a dispute can be raised on now, if any.
  Milestone? get disputableMilestone => _latest
      .where((m) =>
          m.status == MilestoneStatus.funded ||
          m.status == MilestoneStatus.submitted)
      .firstOrNull;

  bool get hasOpenDispute =>
      _latest.any((m) => m.status == MilestoneStatus.disputed);

  /// Opens the dispute sheet for [disputableMilestone].
  Future<void> raiseDispute() async {
    final m = disputableMilestone;
    if (m != null) await _dispute(m);
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

  /// The raiser takes back their dispute; the milestone carries on as before.
  Future<void> _withdraw(Milestone milestone) async {
    final repo = context.read<DisputeRepository>();
    final confirmed = await _confirm(
      title: 'Withdraw your dispute?',
      body:
          'The admin will stop reviewing it and "${milestone.description}" '
          'goes back to where it was. No money moves.',
      actionLabel: 'Withdraw',
    );
    if (confirmed != true || !mounted) return;
    await _run(
      milestone,
      () => repo.withdrawDispute(
        jobId: milestone.jobId,
        milestoneId: milestone.id,
      ),
      step: 'dispute.withdraw',
    );
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
  /// action for diagnostic logging (e.g. `'milestone.release'`).
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
      // One central confirmation for deliver / release: money has
      // moved, so acknowledge it in the hand too. Never awaited - a haptic
      // failure must not be caught below and reported as a payment failure.
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

  /// Runs the current step's action - deliver or release, whichever
  /// the viewer can take - as the bottom bar's button. Does nothing when
  /// there is none or another action is still running.
  Future<void> runCurrentAction() async {
    if (_busyId != null) return;
    final myUid = context.read<AuthController>().user?.uid;
    final currentId = _currentStepId(_latest);
    for (final m in _latest) {
      if (m.id != currentId) continue;
      final action = _actionFor(
        m,
        isRequestor: myUid == widget.job.requestorId,
        isProvider: myUid == widget.job.acceptedProviderId,
      );
      await action?.$2();
    }
  }

  /// The one action the viewer can take on [milestone] right now, or null.
  (String, Future<void> Function())? _actionFor(
    Milestone milestone, {
    required bool isRequestor,
    required bool isProvider,
  }) {
    return switch (milestone.status) {
      MilestoneStatus.funded when isProvider => (
        'Mark as delivered',
        () => _deliver(milestone),
      ),
      MilestoneStatus.submitted when isRequestor => (
        'Release payment',
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

  /// A milestone id, or `'complete'` - the step that's dominant right now.
  /// See the class doc for the rule.
  String _currentStepId(List<Milestone> milestones) {
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
    final currentId = _currentStepId(milestones);

    final rows = <Widget>[];
    var previousDone = false;

    for (final (i, m) in milestones.indexed) {
      final isCurrent = currentId == m.id;
      final done = _isTerminal(m.status);
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
    final totalSteps = totalMilestones + 1; // + job complete.
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

    // `Border` can't mix a coloured left accent with a differently-coloured
    // frame and a borderRadius in one go (Flutter's non-uniform-border paint
    // path only supports a single visible colour) - so the accent is a
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
                      Text(
                        '$index. ${m.description}',
                        style: theme.textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 8),
                      // Own line so the pill keeps its full text at large
                      // text scales instead of being squeezed and truncated.
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
        MilestoneStatus.submitted => isRequestor,
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

  /// The collapsed one-line summary for a done or upcoming milestone step.
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

/// Gutter circle shape per state (WCAG 1.4.1: shape carries the state, not
/// just colour) - filled-with-check (done), ring-with-lock (in escrow),
/// hollow (upcoming), filled-with-`!` (disputed).
enum _CircleState { done, inEscrow, upcoming, disputed }

_CircleState _circleStateFor(MilestoneStatus s) => switch (s) {
  MilestoneStatus.released ||
  MilestoneStatus.resolved ||
  MilestoneStatus.refunded => _CircleState.done,
  MilestoneStatus.funded || MilestoneStatus.submitted => _CircleState.inEscrow,
  MilestoneStatus.disputed => _CircleState.disputed,
  MilestoneStatus.proposed || MilestoneStatus.pending => _CircleState.upcoming,
};

/// Status-chip colour per state - [FairBidColors.warningText] (not the raw
/// `warning` fill) so the pill's text/icon keeps readable contrast.
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

IconData _statusIcon(MilestoneStatus s) => switch (s) {
  MilestoneStatus.proposed || MilestoneStatus.pending => Icons.hourglass_empty,
  MilestoneStatus.funded => Icons.lock_outline,
  MilestoneStatus.submitted => Icons.inventory_2_outlined,
  MilestoneStatus.released => Icons.check_circle_outline,
  MilestoneStatus.disputed => Icons.gavel_rounded,
  MilestoneStatus.resolved => Icons.info_outline,
  MilestoneStatus.refunded => Icons.undo,
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
      // successText, not success: a white tick on the brighter fill sits at
      // 2.02:1, so the "this milestone is paid out" state was carried by
      // shape alone at the exact moment money had moved.
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

/// "Your turn" (accent-filled) vs "Waiting on {name}" (neutral outline) -
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

/// The card above the tracker: total, a segmented Paid out / In escrow / Not
/// funded bar (word + icon per segment, never colour alone), and a plain-
/// language reassurance for first-time requestors.
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
    final refundedSen = milestones
        .where((m) => m.status == MilestoneStatus.refunded)
        .fold<int>(0, (s, m) => s + m.amountSen);
    final notFundedSen = totalSen - paidOutSen - inEscrowSen - refundedSen;

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
                  if (refundedSen > 0)
                    Expanded(
                      flex: refundedSen,
                      child: Container(
                        height: 8,
                        color: theme.colorScheme.onSurfaceVariant,
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
