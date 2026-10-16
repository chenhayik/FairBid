import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/money.dart';
import '../../../core/util/time_ago.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/form_widgets.dart';
import '../../../core/widgets/keyed_stream_builder.dart';
import '../../admin/domain/pending_verification.dart';
import '../../admin/presentation/widgets/document_gallery.dart';
import '../../messages/data/chat_repository.dart';
import '../../messages/domain/message.dart';
import '../data/dispute_repository.dart';
import '../domain/dispute.dart';

/// What:   Admin ruling screen for one dispute.
/// Input:  [dispute] from the queue; chat via ChatRepository.watchMessages() (chat_repository.dart).
/// Output: Statement, evidence and chat; Pay / Refund calls resolveDispute then pops.
class DisputeDetailScreen extends StatefulWidget {
  const DisputeDetailScreen({super.key, required this.dispute});

  final Dispute dispute;

  @override
  State<DisputeDetailScreen> createState() => _DisputeDetailScreenState();
}

class _DisputeDetailScreenState extends State<DisputeDetailScreen> {
  bool _busy = false;

  Dispute get d => widget.dispute;

  /// What:   Rules on the dispute with a required explanation.
  /// Input:  [resolution]; the note typed in a ReasonDialog (null = cancelled).
  /// Output: DisputeRepository.resolveDispute(), then pops with a snackbar; on failure stays and shows the error.
  /// Notes:  The messenger is captured before the pop so the snackbar lands on the queue.
  Future<void> _rule(DisputeResolution resolution) async {
    final release = resolution == DisputeResolution.release;
    final note = await showDialog<String>(
      context: context,
      builder: (context) => ReasonDialog(
        title: release
            ? 'Pay the provider?'
            : 'Refund the client and end the job?',
        message: release
            ? 'The money in this dispute goes to the provider. '
                'Explain why; both sides will see it.'
            : 'All money still held goes back to the client and the job '
                'is cancelled. Explain why; both sides will see it.',
        hint: 'e.g. Delivered work matches the milestone scope.',
        confirmLabel: release ? 'Pay provider' : 'Refund and end job',
        confirmColor: release ? null : context.fairbid.danger,
      ),
    );
    // Null means cancelled; the dialog enforces a non-empty note.
    if (note == null || !mounted) return;

    // Captured early: this screen's context is gone after the pop, and the snackbar belongs on the queue.
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
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(
          content: Text((e is FirebaseFunctionsException ? e.message : null) ??
              'Could not save the ruling. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Dispute Review')),
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

/// What:   Job and milestone summary, disputed amount and who raised it.
/// Input:  [dispute] passed from the screen.
/// Output: AppCard with title, "Raised by" pill, amount in escrow and a short case id with its age.
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

/// What:   Read-only job chat (client left, provider right) for weighing what was agreed.
/// Input:  ChatRepository.watchMessages(dispute.conversationId) (chat_repository.dart).
/// Output: Messages oldest first with a count line, or an empty state.
/// How:    The repository returns newest first, so the list is reversed for reading.
class _ChatHistoryCard extends StatelessWidget {
  const _ChatHistoryCard({required this.dispute});

  final Dispute dispute;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: KeyedStreamBuilder<List<Message>>(
        cacheKey: dispute.conversationId,
        create: () =>
            context.read<ChatRepository>().watchMessages(dispute.conversationId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          // Repository gives newest-first; reverse for reading.
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
                  isProvider: message.senderId == dispute.providerId,
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

/// What:   One chat message, client left in grey and provider right in blue.
/// Input:  [message]; [isProvider] when the sender is the dispute's provider.
/// Output: Bubble with role label, text and time ago.
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

/// What:   Sticky bottom bar with the Pay and Refund rulings.
/// Input:  [amountSen] shown on the Pay button; [busy]; [onRelease] / [onRefund] callbacks.
/// Output: Two stacked buttons above a top border.
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
      // Stacked so each label can be explicit.
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
