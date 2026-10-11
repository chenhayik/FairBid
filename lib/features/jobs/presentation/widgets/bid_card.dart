import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/money.dart';
import '../../../../core/util/time_ago.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/user_chip.dart';
import '../../domain/bid.dart';

/// What:   One bid as the requestor sees it.
/// Input:  [bid] from BidRepository.watchBids(); [onAccept] while the job is open.
/// Output: Provider, price, duration, proposal and an Accept bid button.
class BidCard extends StatelessWidget {
  const BidCard(
      {super.key,
      required this.bid,
      this.onAccept,
      this.isBestValue = false,
      this.busy = false,
      this.enabled = true});

  final Bid bid;

  /// Shows the "Accept bid" button when set.
  final VoidCallback? onAccept;

  /// This bid's accept is in flight (a server transaction); the button spins.
  final bool busy;

  /// False on the other cards while one accept runs, so the button greys out.
  final bool enabled;

  /// The top bid by price and trust; wears a "BEST VALUE" pill.
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
              color: context.fairbid.successText,
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              // Only the identity row opens the profile; the card owns Accept.
              Expanded(
                child: UserChip(
                  uid: bid.providerId,
                  name: bid.providerName,
                  photoUrl: bid.providerPhotoUrl,
                  nameStyle: theme.textTheme.titleLarge,
                  // Don't show the internal ranking prior as an earned score.
                  subtitle: bid.providerScoreVisible
                      ? 'Trust Score $trustPercent/100'
                      : 'New provider, no score yet',
                ),
              ),
              const SizedBox(width: 8),
              PillBadge(
                label: bid.providerScoreVisible ? 'Verified' : 'New',
                icon: bid.providerScoreVisible
                    ? Icons.verified
                    : Icons.auto_awesome,
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
            PrimaryButton(
              label: 'Accept bid',
              onPressed: enabled ? onAccept : null,
              busy: busy,
            ),
          ],
        ],
      ),
    );
  }
}
