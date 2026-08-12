import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/money.dart';
import '../../../core/util/time_ago.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/keyed_stream_builder.dart';
import '../data/dispute_repository.dart';
import '../domain/dispute.dart';

/// Admin Home › Disputes tab: every open milestone dispute, oldest first, for
/// the admin to open and rule on. Mirrors the verification queue.
class DisputeQueueScreen extends StatelessWidget {
  const DisputeQueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return KeyedStreamBuilder<List<Dispute>>(
      create: context.read<DisputeRepository>().watchOpenDisputes,
      builder: (context, snapshot) {
        final items = snapshot.data;
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('Disputes Resolution', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 4),
            Text('Review and arbitrate active disputes between clients and '
                'providers.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 24),
            StatCard(
              label: 'Open Disputes',
              value: items == null ? '-' : '${items.length}',
              icon: Icons.gavel_rounded,
            ),
            const SizedBox(height: 24),
            if (snapshot.hasError)
              const AppCard(
                child: EmptyState(
                  icon: Icons.error_outline,
                  title: 'Couldn\'t load disputes',
                  message: 'Check your connection and try again.',
                ),
              )
            else if (items == null)
              const Padding(
                padding: EdgeInsets.only(top: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (items.isEmpty)
              const AppCard(
                child: EmptyState(
                  icon: Icons.handshake_outlined,
                  title: 'No open disputes',
                  message: 'When a client or provider disputes an escrowed '
                      'milestone, it will appear here for a ruling.',
                ),
              )
            else
              for (final dispute in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _DisputeCard(
                    dispute: dispute,
                    onTap: () =>
                        context.push('/admin/dispute', extra: dispute),
                  ),
                ),
          ],
        );
      },
    );
  }
}

/// One open dispute in the queue list.
class _DisputeCard extends StatelessWidget {
  const _DisputeCard({required this.dispute, required this.onTap});

  final Dispute dispute;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final danger = context.fairbid.danger;
    return AppCard(
        onTap: onTap,
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: danger.withValues(alpha: 0.1),
              child: Icon(Icons.gavel_rounded, color: danger),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(dispute.jobTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                      '${dispute.milestoneDescription} · '
                      '${formatRm(dispute.amountSen)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Flexible(
                        child: PillBadge(
                          label: 'Raised by ${dispute.raisedByLabel}',
                          icon: Icons.flag_outlined,
                          color: danger,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (dispute.createdAt != null)
                        Text(timeAgo(dispute.createdAt),
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      );
  }
}
