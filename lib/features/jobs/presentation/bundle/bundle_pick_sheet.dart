import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/money.dart';
import '../../../../core/widgets/app_widgets.dart';
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
              title: Text(bid.providerName),
              subtitle: Wrap(
                spacing: 8,
                children: [
                  if (bid.priceFor(taskId) == lowest)
                    PillBadge(
                      label: 'Lowest price',
                      color: context.fairbid.verified,
                    ),
                  if (bid.bundlePriceSen != null)
                    Text(
                      'Bundle price ${formatRm(bid.bundlePriceSen!)} if they '
                      'win all ${bid.taskCount} tasks',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
              trailing: Text(
                formatRm(bid.priceFor(taskId)!),
                style: theme.textTheme.titleSmall,
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
