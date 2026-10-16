import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/money.dart';
import '../../../core/util/time_ago.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/keyed_stream_builder.dart';
import '../data/verification_repository.dart';
import '../domain/pending_verification.dart';

/// What:   Admin Verifications tab: users awaiting review.
/// Input:  Pending users via VerificationRepository.watchPending() (verification_repository.dart).
/// Output: Cards that open the detail screen; hosted by AdminHomeScreen.
class VerificationQueueScreen extends StatelessWidget {
  const VerificationQueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return KeyedStreamBuilder<List<PendingVerification>>(
      create: context.read<VerificationRepository>().watchPending,
      builder: (context, snapshot) {
        final items = snapshot.data;
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('Verification Queue',
                style: theme.textTheme.headlineMedium),
            const SizedBox(height: 4),
            Text('Review identity documents and approve marketplace access.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 24),
            StatCard(
              label: 'Pending Review',
              value: items == null ? '-' : formatCount(items.length),
              icon: Icons.verified_user_outlined,
            ),
            const SizedBox(height: 24),
            if (snapshot.hasError)
              const AppCard(
                child: EmptyState(
                  icon: Icons.error_outline,
                  title: 'Couldn\'t load the queue',
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
                  icon: Icons.inbox_outlined,
                  title: 'All caught up',
                  message:
                      'No pending verifications right now. New submissions '
                      'will appear here for review.',
                ),
              )
            else
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _QueueCard(
                    item: item,
                    onTap: () => context.push('/admin/verify', extra: item),
                  ),
                ),
          ],
        );
      },
    );
  }
}

/// What:   One pending applicant row.
/// Input:  [item], a PendingVerification; [onTap] opens the detail screen.
/// Output: AppCard with avatar, name, email, role pill and time submitted.
class _QueueCard extends StatelessWidget {
  const _QueueCard({required this.item, required this.onTap});

  final PendingVerification item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
        onTap: onTap,
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: context.fairbid.subtleBlue,
              child: Icon(
                item.isProvider ? Icons.handyman_outlined : Icons.person_outline,
                color: context.fairbid.verified,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  if (item.email != null)
                    Text(item.email!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Flexible(
                        child: PillBadge(
                          label: item.roleSummary,
                          icon: item.isProvider
                              ? Icons.handyman_outlined
                              : Icons.person_outline,
                          color: item.isProvider
                              ? context.fairbid.verified
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (item.submittedAt != null)
                        Text(timeAgo(item.submittedAt),
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
