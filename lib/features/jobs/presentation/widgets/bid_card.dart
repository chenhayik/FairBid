import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/money.dart';
import '../../../../core/util/time_ago.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/user_chip.dart';
import '../../domain/bid.dart';

/// One bid as the requestor sees it: provider identity, price, duration and
/// proposal, with an Accept action while the job is still open.
class BidCard extends StatelessWidget {
  const BidCard(
      {super.key,
      required this.bid,
      this.onAccept,
      this.isBestValue = false,
      this.busy = false,
      this.enabled = true});

  final Bid bid;

  /// Shown as an "Accept Bid" button when non-null (job still open).
  final VoidCallback? onAccept;

  /// Whether this bid's accept is in flight. Accepting runs a server
  /// transaction that can take a second or two, so the button spins rather
  /// than sitting inert and inviting a second tap on another provider.
  final bool busy;

  /// Whether the accept action can be taken. Set false on the *other* cards
  /// while one accept is in flight, so the button greys out instead of
  /// disappearing (which is what nulling [onAccept] would do).
  final bool enabled;

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
              color: context.fairbid.successText,
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              // Only the identity row is tappable (through to the provider's
              // public profile) - not the whole card, which already owns the
              // Accept Bid action below.
              Expanded(
                child: UserChip(
                  uid: bid.providerId,
                  name: bid.providerName,
                  photoUrl: bid.providerPhotoUrl,
                  nameStyle: theme.textTheme.titleLarge,
                  // A provider who hasn't earned a visible score yet is
                  // labelled honestly instead of showing the internal
                  // ranking prior as if it were earned.
                  subtitle: bid.providerScoreVisible
                      ? 'Trust Score $trustPercent/100'
                      : 'New provider, no score yet',
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
            PrimaryButton(
              label: 'Accept Bid',
              onPressed: enabled ? onAccept : null,
              busy: busy,
            ),
          ],
        ],
      ),
    );
  }
}
