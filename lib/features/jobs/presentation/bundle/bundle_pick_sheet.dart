import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/money.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/user_avatar.dart';
import '../../domain/bundle_bid.dart';
import 'bundle_pick_logic.dart';

/// Result of [showBundlePickSheet] for "Don't award" (null means dismissed).
const bundleNoProviderPick = '';

/// What:   Bottom sheet listing every bid covering [taskId], cheapest first.
/// Input:  [bids] from the bundle screen; [currentProviderId] is highlighted.
/// Output: The chosen provider id, or [bundleNoProviderPick].
Future<String?> showBundlePickSheet(
  BuildContext context, {
  required String title,
  required String taskId,
  required List<BundleBid> bids,
  required String? currentProviderId,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _PickSheet(
      title: title,
      taskId: taskId,
      bids: bidsCoveringTask(bids, taskId),
      currentProviderId: currentProviderId,
    ),
  );
}

/// What:   The bundle-deal line of a bid.
/// Input:  [bid] with a bundle price.
/// Output: "Bundle deal RM x if they win all N tasks", plus "(saves RM y)" when y is above 0.
String _bundleNote(BundleBid bid) {
  final saving = bid.taskTotalSen - bid.bundlePriceSen!;
  return 'Bundle deal ${formatRm(bid.bundlePriceSen!)} if they win all '
      '${bid.taskCount} tasks${saving > 0 ? ' (saves ${formatRm(saving)})' : ''}';
}

/// What:   Sheet body listing the bids for one task.
/// Input:  [bids] already filtered and sorted by bidsCoveringTask(); [currentProviderId] is highlighted.
/// Output: Rows with avatar, "Lowest price alone" badge, bundle-deal note and a profile button (keeps the sheet open); pops with the provider id, or [bundleNoProviderPick].
class _PickSheet extends StatelessWidget {
  const _PickSheet({
    required this.title,
    required this.taskId,
    required this.bids,
    required this.currentProviderId,
  });

  final String title;
  final String taskId;
  final List<BundleBid> bids;
  final String? currentProviderId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lowest = bids.isEmpty ? null : bids.first.priceFor(taskId);
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final bid in bids)
            ListTile(
              contentPadding: EdgeInsets.zero,
              selected: bid.providerId == currentProviderId,
              onTap: () => Navigator.of(context).pop(bid.providerId),
              leading: UserAvatar(photoUrl: bid.providerPhotoUrl),
              title: Text(bid.providerName),
              subtitle: Wrap(
                spacing: 8,
                children: [
                  if (bid.priceFor(taskId) == lowest)
                    PillBadge(
                      label: 'Lowest price alone',
                      color: context.fairbid.verified,
                    ),
                  if (bid.bundlePriceSen != null)
                    Text(_bundleNote(bid), style: theme.textTheme.bodySmall),
                ],
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    formatRm(bid.priceFor(taskId)!),
                    style: theme.textTheme.titleSmall,
                  ),
                  IconButton(
                    tooltip: 'View profile',
                    icon: const Icon(Icons.person_outline),
                    onPressed: () => context.push('/users/${bid.providerId}'),
                  ),
                ],
              ),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            onTap: () => Navigator.of(context).pop(bundleNoProviderPick),
            title: const Text("Don't award"),
          ),
        ],
      ),
    );
  }
}
