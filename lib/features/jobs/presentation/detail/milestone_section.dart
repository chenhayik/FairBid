import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/money.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../auth/presentation/auth_controller.dart';
import '../../../disputes/presentation/raise_dispute_sheet.dart';
import '../../data/milestone_repository.dart';
import '../../domain/job.dart';
import '../../domain/milestone.dart';
import 'propose_milestones_sheet.dart';

/// The escrow milestone plan on a job detail. The accepted provider proposes
/// it; then per milestone the requestor funds, the provider delivers and the
/// requestor releases payment. Releasing the last milestone completes the job
/// (server-side, via the `releaseMilestone` Cloud Function), which is what
/// unlocks reviews.
class MilestoneSection extends StatefulWidget {
  const MilestoneSection(
      {super.key, required this.job, required this.onChanged});

  final Job job;

  /// Called after an action that may have changed the job document itself
  /// (releasing the last milestone completes the job), so the parent screen
  /// re-fetches it.
  final VoidCallback onChanged;

  @override
  State<MilestoneSection> createState() => _MilestoneSectionState();
}

class _MilestoneSectionState extends State<MilestoneSection> {
  // Cached so rebuilds don't resubscribe to Firestore.
  late final Stream<List<Milestone>> _milestones;

  /// The milestone with an action call in flight, disabling its button — or
  /// [_planBusyKey] while a plan-level (approve/reject) action runs.
  String? _busyId;

  /// Sentinel [_busyId] value for plan-level actions (no single milestone id).
  static const _planBusyKey = '__plan__';

  @override
  void initState() {
    super.initState();
    _milestones =
        context.read<MilestoneRepository>().watchMilestones(widget.job.id);
  }

  Future<void> _fund(Milestone milestone) async {
    final repo = context.read<MilestoneRepository>();
    final confirmed = await _confirm(
      title: 'Fund this milestone?',
      body: '${formatRm(milestone.amountSen)} will be moved from your wallet '
          'and held in escrow for "${milestone.description}" until you '
          'release it.',
      actionLabel: 'Fund',
    );
    if (confirmed != true || !mounted) return;
    // Funding debits the requestor's wallet, so refresh the profile after.
    await _run(milestone,
        () => repo.fundMilestone(milestone.jobId, milestone.id),
        refreshBalance: true);
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
                'the payment.'),
            const SizedBox(height: 12),
            TextField(
              controller: note,
              maxLines: 3,
              decoration: const InputDecoration(
                  hintText: 'Delivery note (optional)'),
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
        () => repo.submitMilestone(milestone.jobId, milestone.id,
            note: text.isEmpty ? null : text));
  }

  Future<void> _release(Milestone milestone) async {
    final repo = context.read<MilestoneRepository>();
    final confirmed = await _confirm(
      title: 'Release payment?',
      body: '${formatRm(milestone.amountSen)} will be paid to '
          '${widget.job.acceptedProviderName ?? 'the provider'} for '
          '"${milestone.description}". This cannot be undone.',
      actionLabel: 'Release',
    );
    if (confirmed != true || !mounted) return;
    // A release may complete the job (last milestone), so reload it after.
    await _run(milestone,
        () => repo.releaseMilestone(milestone.jobId, milestone.id),
        reloadJob: true);
  }

  Future<void> _dispute(Milestone milestone) async {
    final raised =
        await RaiseDisputeSheet.show(context, milestone: milestone);
    if (raised == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Dispute submitted — an admin will review it and '
              'decide on the escrowed payment.')));
    }
  }

  /// Requestor approves the proposed plan, making every milestone fundable.
  Future<void> _approvePlan() async {
    final repo = context.read<MilestoneRepository>();
    final confirmed = await _confirm(
      title: 'Approve this plan?',
      body: 'You\'ll then fund each milestone into escrow and release payment '
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
              decoration:
                  const InputDecoration(hintText: 'What should change?'),
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
    await _runPlan(() => repo.rejectMilestonePlan(widget.job.id,
        note: text.isEmpty ? null : text));
  }

  /// Provider revises the plan (opens the propose sheet pre-filled).
  Future<void> _amendPlan(List<Milestone> milestones) async {
    final changed = await ProposeMilestonesSheet.show(context,
        job: widget.job, existing: milestones);
    if (changed == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Updated plan sent to the client for approval.')));
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.message ?? 'Something went wrong. Please try again.')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Something went wrong. Please try again.')));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<bool?> _confirm(
      {required String title,
      required String body,
      required String actionLabel}) {
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
  /// Cloud Function's user-readable message on failure.
  Future<void> _run(Milestone milestone, Future<void> Function() action,
      {bool refreshBalance = false, bool reloadJob = false}) async {
    setState(() => _busyId = milestone.id);
    try {
      await action();
      if (!mounted) return;
      if (refreshBalance) await context.read<AuthController>().refreshUser();
      if (reloadJob) widget.onChanged();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      var message = e.message ?? 'Something went wrong. Please try again.';
      if (message.startsWith('Insufficient')) {
        message = '$message Top up from Profile → My Wallet.';
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Something went wrong. Please try again.')));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
        final milestones = snapshot.data ?? [];
        if (milestones.isEmpty) return _emptyState(job, isProvider);

        final planIsProposed =
            milestones.any((m) => m.status == MilestoneStatus.proposed);
        // The provider may revise the plan only while nothing is funded yet.
        final planEditable = job.status == JobStatus.inProgress &&
            milestones.every((m) =>
                m.status == MilestoneStatus.proposed ||
                m.status == MilestoneStatus.pending);
        final planBusy = _busyId == _planBusyKey;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Milestones', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            if (planIsProposed && isRequestor) ...[
              _PlanApprovalBar(
                busy: planBusy,
                onApprove: _approvePlan,
                onReject: _rejectPlan,
              ),
              const SizedBox(height: 12),
            ],
            if (planIsProposed && isProvider) ...[
              const InfoBanner(
                icon: Icons.hourglass_empty,
                title: 'Awaiting client approval',
                body: 'The client is reviewing your proposed plan. They\'ll '
                    'fund the first milestone once they approve it.',
              ),
              const SizedBox(height: 12),
            ],
            for (final (i, milestone) in milestones.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _MilestoneCard(
                  index: i + 1,
                  milestone: milestone,
                  busy: _busyId == milestone.id,
                  action: _actionFor(milestone,
                      isRequestor: isRequestor, isProvider: isProvider),
                  // Escrowed money is at stake exactly while funded/delivered,
                  // so either party may freeze it for admin review.
                  onDispute: milestone.status == MilestoneStatus.funded ||
                          milestone.status == MilestoneStatus.submitted
                      ? () => _dispute(milestone)
                      : null,
                ),
              ),
            // The provider can revise the plan until the client funds a
            // milestone; any change re-enters approval.
            if (isProvider && planEditable && !planIsProposed)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: planBusy ? null : () => _amendPlan(milestones),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Amend plan'),
                ),
              ),
          ],
        );
      },
    );
  }

  /// No plan yet: the provider gets the propose entry while the job is in
  /// progress; the requestor sees what they're waiting for.
  Widget _emptyState(Job job, bool isProvider) {
    if (job.status != JobStatus.inProgress) return const SizedBox.shrink();
    if (isProvider) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (job.planRejectionNote != null) ...[
            InfoBanner(
              icon: Icons.error_outline,
              title: 'The client asked for changes',
              body: job.planRejectionNote!,
            ),
            const SizedBox(height: 12),
          ],
          InfoBanner(
            icon: Icons.flag_outlined,
            title: 'Propose your milestone plan',
            body: 'Split the accepted '
                '${formatRm(job.acceptedBidAmountSen ?? 0)} into milestones. '
                'The client approves the plan, then funds each one into escrow '
                'before you start, releasing payment as work is approved.',
          ),
          const SizedBox(height: 12),
          PrimaryButton(
            label: 'Propose Milestones',
            onPressed: () => ProposeMilestonesSheet.show(context, job: job),
          ),
        ],
      );
    }
    return const InfoBanner(
      icon: Icons.flag_outlined,
      title: 'Milestones',
      body: 'Waiting for the provider to propose a milestone plan. You\'ll '
          'fund each milestone into escrow and release payment as work is '
          'approved.',
    );
  }

  /// The one action the viewer can take on [milestone] right now, or null.
  (String, Future<void> Function())? _actionFor(Milestone milestone,
      {required bool isRequestor, required bool isProvider}) {
    return switch (milestone.status) {
      MilestoneStatus.pending when isRequestor => (
          'Fund Milestone',
          () => _fund(milestone)
        ),
      MilestoneStatus.funded when isProvider => (
          'Mark as Delivered',
          () => _deliver(milestone)
        ),
      MilestoneStatus.submitted when isRequestor => (
          'Release Payment',
          () => _release(milestone)
        ),
      _ => null,
    };
  }
}

class _MilestoneCard extends StatelessWidget {
  const _MilestoneCard({
    required this.index,
    required this.milestone,
    required this.busy,
    this.action,
    this.onDispute,
  });

  final int index;
  final Milestone milestone;
  final bool busy;
  final (String, Future<void> Function())? action;

  /// Opens the Raise Dispute sheet; null when this milestone can't be
  /// disputed (not funded/delivered).
  final VoidCallback? onDispute;

  /// Status-chip colours per DESIGN.md §6.7.
  Color _statusColor(BuildContext context) => switch (milestone.status) {
        MilestoneStatus.proposed ||
        MilestoneStatus.pending ||
        MilestoneStatus.submitted =>
          context.fairbid.warning,
        MilestoneStatus.funded => context.fairbid.verified,
        MilestoneStatus.released => context.fairbid.success,
        MilestoneStatus.disputed => context.fairbid.danger,
        MilestoneStatus.resolved =>
          Theme.of(context).colorScheme.onSurfaceVariant,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text('$index. ${milestone.description}',
                    style: theme.textTheme.bodyLarge),
              ),
              const SizedBox(width: 8),
              PillBadge(
                label: milestone.status.label,
                color: _statusColor(context),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            formatRm(milestone.amountSen),
            style: theme.textTheme.titleLarge
                ?.copyWith(color: context.fairbid.verified),
          ),
          if (milestone.submissionNote != null) ...[
            const SizedBox(height: 4),
            Text(
              'Delivery note: ${milestone.submissionNote}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
          if (milestone.reworkNote != null) ...[
            const SizedBox(height: 4),
            Text(
              'Sent back for rework: ${milestone.reworkNote}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: context.fairbid.danger),
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: 12),
            PrimaryButton(
              label: action!.$1,
              busy: busy,
              onPressed: () => action!.$2(),
            ),
          ],
          if (onDispute != null)
            Center(
              child: TextButton(
                onPressed: busy ? null : onDispute,
                style: TextButton.styleFrom(
                    foregroundColor: context.fairbid.danger),
                child: const Text('Raise a dispute'),
              ),
            ),
        ],
      ),
    );
  }
}

/// The requestor's plan-level consent step: approve the proposed split (which
/// makes every milestone fundable) or send it back for changes.
class _PlanApprovalBar extends StatelessWidget {
  const _PlanApprovalBar({
    required this.busy,
    required this.onApprove,
    required this.onReject,
  });

  final bool busy;
  final Future<void> Function() onApprove;
  final Future<void> Function() onReject;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Approve the milestone plan',
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'The provider proposed how to split the accepted bid. Approve it to '
            'start funding, or ask for changes.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          PrimaryButton(
            label: 'Approve Plan',
            busy: busy,
            onPressed: () => onApprove(),
          ),
          const SizedBox(height: 8),
          SecondaryButton(
            label: 'Request Changes',
            onPressed: busy ? null : () => onReject(),
          ),
        ],
      ),
    );
  }
}
