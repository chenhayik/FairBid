import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/money.dart';
import '../../../core/util/time_ago.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../admin/domain/pending_verification.dart';
import '../../admin/presentation/widgets/document_gallery.dart';
import '../../jobs/data/job_repository.dart';
import '../../messages/data/chat_repository.dart';
import '../../messages/domain/message.dart';
import '../data/dispute_repository.dart';
import '../domain/dispute.dart';

/// The ruling screen an admin opens from the dispute queue: the raiser's
/// statement, photo evidence and the job's chat history, then a Release /
/// Refund decision on the escrowed amount.
class DisputeDetailScreen extends StatefulWidget {
  const DisputeDetailScreen({super.key, required this.dispute});

  final Dispute dispute;

  @override
  State<DisputeDetailScreen> createState() => _DisputeDetailScreenState();
}

class _DisputeDetailScreenState extends State<DisputeDetailScreen> {
  bool _busy = false;

  Dispute get d => widget.dispute;

  Future<void> _rule(DisputeResolution resolution) async {
    final note = await showDialog<String>(
      context: context,
      builder: (context) => _RulingNoteDialog(resolution: resolution),
    );
    // Null → the admin cancelled. The dialog enforces a non-empty note.
    if (note == null || !mounted) return;

    // Capture the messenger before the async gap and the pop, so the snackbar
    // shows on the queue (this screen's context is gone once we pop).
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await context.read<DisputeRepository>().resolveDispute(
          disputeId: d.id, resolution: resolution, rulingNote: note);
      if (!mounted) return;
      context.pop();
      messenger.showSnackBar(SnackBar(
        content: Text(resolution == DisputeResolution.release
            ? '${formatRm(d.amountSen)} paid to the provider.'
            : 'The client was refunded and the job has ended.'),
      ));
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(
          content:
              Text(e.message ?? 'Could not save the ruling. Please try again.')));
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(const SnackBar(
          content: Text('Could not save the ruling. Please try again.')));
    }
  }

  /// Admin override: cancels the whole job. Refused server-side while any
  /// milestone still holds escrow - so in practice the admin rules on (and
  /// thereby settles) the open disputes first, then cancels an otherwise
  /// unworkable job. The clear server message is surfaced when it's blocked.
  Future<void> _cancelJob() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel the entire job?'),
        content: const Text(
            'This ends the job for both parties. It only works once no '
            'milestone holds escrow. Settle any funded milestone or open '
            'dispute first.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Back'),
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
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await context.read<JobRepository>().adminCancelJob(d.jobId);
      if (!mounted) return;
      context.pop();
      messenger.showSnackBar(
          const SnackBar(content: Text('Job cancelled.')));
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(
          content: Text(
              e.message ?? 'Could not cancel the job. Please try again.')));
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(const SnackBar(
          content: Text('Could not cancel the job. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dispute Review'),
        actions: [
          PopupMenuButton<String>(
            enabled: !_busy,
            onSelected: (v) {
              if (v == 'cancel_job') _cancelJob();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'cancel_job',
                child: Text('Cancel entire job'),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  _DisputeHeader(dispute: d),
                  const SizedBox(height: 24),
                  Text('Statement', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 12),
                  AppCard(
                    child: Text(d.statement, style: theme.textTheme.bodyMedium),
                  ),
                  const SizedBox(height: 24),
                  Text('Evidence (${d.evidenceUrls.length})',
                      style: theme.textTheme.titleLarge),
                  const SizedBox(height: 12),
                  DocumentGallery(
                    documents: [
                      for (final (i, url) in d.evidenceUrls.indexed)
                        VerificationDocument(
                            label: 'Evidence ${i + 1}', url: url),
                    ],
                    emptyTitle: 'No evidence attached',
                    emptyMessage:
                        'The dispute was raised without photos. Rule on the '
                        'statement and the chat history.',
                  ),
                  const SizedBox(height: 24),
                  Text('Chat History', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 12),
                  _ChatHistoryCard(dispute: d),
                  const SizedBox(height: 24),
                  InfoBanner(
                    icon: Icons.gpp_good_outlined,
                    title: 'Your two choices',
                    body: 'Pay the provider: ${formatRm(d.amountSen)} goes to '
                        'the provider and the work carries on.\n'
                        'Refund the client: all money still held for this job '
                        'goes back to the client, the job ends, and it counts '
                        'against the provider.\n'
                        'Both are final.',
                  ),
                ],
              ),
            ),
            _RulingBar(
              amountSen: d.amountSen,
              busy: _busy,
              onRefund: () => _rule(DisputeResolution.refund),
              onRelease: () => _rule(DisputeResolution.release),
            ),
          ],
        ),
      ),
    );
  }
}

/// Job/milestone summary, the disputed amount and who raised it.
class _DisputeHeader extends StatelessWidget {
  const _DisputeHeader({required this.dispute});

  final Dispute dispute;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final danger = context.fairbid.danger;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(dispute.jobTitle,
                    style: theme.textTheme.titleLarge),
              ),
              PillBadge(
                label: 'Raised by ${dispute.raisedByLabel}',
                icon: Icons.flag_outlined,
                color: danger,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(dispute.milestoneDescription,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          Text('AMOUNT IN ESCROW', style: theme.textTheme.labelMedium),
          Text(formatRm(dispute.amountSen),
              style: theme.textTheme.headlineMedium
                  ?.copyWith(color: context.fairbid.verified)),
          const SizedBox(height: 8),
          Text(
            'Case #${dispute.id.substring(0, dispute.id.length.clamp(0, 8)).toUpperCase()}'
            '${dispute.createdAt == null ? '' : ' · opened ${timeAgo(dispute.createdAt)}'}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Read-only view of the job's chat thread (client left, provider right) so
/// the admin can weigh what both parties agreed in writing.
class _ChatHistoryCard extends StatefulWidget {
  const _ChatHistoryCard({required this.dispute});

  final Dispute dispute;

  @override
  State<_ChatHistoryCard> createState() => _ChatHistoryCardState();
}

class _ChatHistoryCardState extends State<_ChatHistoryCard> {
  // Cached so rebuilds don't resubscribe to Firestore.
  late final Stream<List<Message>> _messages;

  @override
  void initState() {
    super.initState();
    _messages = context
        .read<ChatRepository>()
        .watchMessages(widget.dispute.conversationId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: StreamBuilder<List<Message>>(
        stream: _messages,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          // Newest-first from the repository → oldest-first for reading.
          final messages = (snapshot.data ?? []).reversed.toList();
          if (messages.isEmpty) {
            return const EmptyState(
              icon: Icons.forum_outlined,
              title: 'No chat history',
              message: 'The parties have not messaged each other on this job.',
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final message in messages)
                _ChatLine(
                  message: message,
                  isProvider: message.senderId == widget.dispute.providerId,
                ),
              const SizedBox(height: 4),
              Text('Showing the latest ${messages.length} messages.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          );
        },
      ),
    );
  }
}

/// One message row: client on the left in grey, provider on the right in blue.
class _ChatLine extends StatelessWidget {
  const _ChatLine({required this.message, required this.isProvider});

  final Message message;
  final bool isProvider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = isProvider
        ? context.fairbid.verified
        : theme.colorScheme.onSurfaceVariant;
    return Align(
      alignment: isProvider ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints:
            BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.6),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isProvider
              ? context.fairbid.subtleBlue
              : theme.colorScheme.surface,
          border: Border.all(color: context.fairbid.borderSubtle),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(isProvider ? 'Provider' : 'Client',
                style: theme.textTheme.labelMedium?.copyWith(color: accent)),
            const SizedBox(height: 2),
            Text(message.text, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 2),
            Text(timeAgo(message.createdAt),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// Sticky bottom bar with the two rulings on the escrowed amount.
class _RulingBar extends StatelessWidget {
  const _RulingBar({
    required this.amountSen,
    required this.busy,
    required this.onRefund,
    required this.onRelease,
  });

  final int amountSen;
  final bool busy;
  final VoidCallback onRefund;
  final VoidCallback onRelease;

  @override
  Widget build(BuildContext context) {
    final danger = context.fairbid.danger;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: context.fairbid.borderSubtle)),
      ),
      // Stacked so each label can say exactly what happens.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryButton(
            label: 'Pay the provider ${formatRm(amountSen)}',
            busy: busy,
            trailingIcon: Icons.check_rounded,
            onPressed: onRelease,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: busy ? null : onRefund,
            style: OutlinedButton.styleFrom(
              foregroundColor: danger,
              side: BorderSide(color: danger),
            ),
            icon: const Icon(Icons.undo_rounded, size: 18),
            label: const Text('Refund the client and end the job'),
          ),
        ],
      ),
    );
  }
}

/// Ruling-note dialog. The note is required - it explains the decision to
/// both parties - so confirm stays disabled until something is typed.
class _RulingNoteDialog extends StatefulWidget {
  const _RulingNoteDialog({required this.resolution});

  final DisputeResolution resolution;

  @override
  State<_RulingNoteDialog> createState() => _RulingNoteDialogState();
}

class _RulingNoteDialogState extends State<_RulingNoteDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final release = widget.resolution == DisputeResolution.release;
    return AlertDialog(
      title: Text(release
          ? 'Pay the provider?'
          : 'Refund the client and end the job?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              release
                  ? 'The money in this dispute goes to the provider. '
                      'Explain why; both sides will see it.'
                  : 'All money still held goes back to the client and the job '
                      'is cancelled. Explain why; both sides will see it.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            maxLines: 3,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'e.g. Delivered work matches the milestone scope.',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: release
              ? null
              : FilledButton.styleFrom(
                  backgroundColor: context.fairbid.danger),
          onPressed: _controller.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(release ? 'Pay provider' : 'Refund and end job'),
        ),
      ],
    );
  }
}
