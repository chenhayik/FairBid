import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/money.dart';
import '../../../../core/util/time_ago.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../domain/bid.dart';

/// One bid as the requestor sees it: provider identity, price, duration and
/// proposal, with an Accept action while the job is still open.
class BidCard extends StatelessWidget {
  const BidCard(
      {super.key, required this.bid, this.onAccept, this.isBestValue = false});

  final Bid bid;

  /// Shown as an "Accept Bid" button when non-null (job still open).
  final VoidCallback? onAccept;

  /// Whether this is the top bid by the price+trust composite. When true the
  /// card wears a success-accented "BEST VALUE" pill (design §6.6).
  final bool isBestValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trustPercent = (bid.providerTrustScore / 10).round();

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isBestValue) ...[
            PillBadge(
              label: 'BEST VALUE',
              icon: Icons.workspace_premium_outlined,
              color: context.fairbid.success,
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              CircleAvatar(
                backgroundColor: context.fairbid.subtleBlue,
                child: Icon(Icons.person_outline,
                    color: context.fairbid.verified),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(bid.providerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge),
                    Text(
                        // A provider who hasn't earned a visible score yet is
                        // labelled honestly instead of showing the internal
                        // ranking prior as if it were earned.
                        bid.providerScoreVisible
                            ? 'Trust Score $trustPercent/100'
                            : 'New provider — no score yet',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (bid.providerScoreVisible)
                PillBadge(
                  label: 'Verified',
                  icon: Icons.verified,
                  color: context.fairbid.verified,
                )
              else
                PillBadge(
                  label: 'New',
                  icon: Icons.auto_awesome,
                  color: context.fairbid.verified,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(formatRm(bid.amountSen),
                    style: theme.textTheme.titleLarge
                        ?.copyWith(color: context.fairbid.verified)),
              ),
              Icon(Icons.schedule,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(bid.estimatedDuration,
                  style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
          if (bid.message.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              bid.message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ],
          const SizedBox(height: 8),
          Text('Bid ${timeAgo(bid.createdAt)}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          if (onAccept != null) ...[
            const SizedBox(height: 12),
            PrimaryButton(label: 'Accept Bid', onPressed: onAccept),
          ],
        ],
      ),
    );
  }
}
