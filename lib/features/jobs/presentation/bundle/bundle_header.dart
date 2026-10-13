import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/widgets/app_widgets.dart';
import '../../domain/bundle.dart';
import '../widgets/status_colors.dart';

/// What:   "Bidding closes/closed 1 Oct 2026" for an open bundle with a deadline.
/// Input:  [bundle].
/// Output: The text, or null (the status pill covers every other state).
String? bundleDeadlineText(Bundle bundle) {
  if (bundle.status != BundleStatus.open || bundle.deadline == null) {
    return null;
  }
  final date = DateFormat.yMMMd().format(bundle.deadline!);
  return bundle.biddingOpen ? 'Bidding closes $date' : 'Bidding closed $date';
}

/// What:   The bundle's status pill.
/// Input:  [bundle].
/// Output: Pill reading "Closed" instead of "Open" once the deadline has passed.
class BundleStatusPill extends StatelessWidget {
  const BundleStatusPill({super.key, required this.bundle});

  final Bundle bundle;

  @override
  Widget build(BuildContext context) {
    final closedByDeadline =
        bundle.status == BundleStatus.open && !bundle.biddingOpen;
    return PillBadge(
      label: closedByDeadline ? 'Closed' : bundle.status.label,
      color: closedByDeadline
          ? Theme.of(context).colorScheme.onSurfaceVariant
          : bundleStatusColor(context, bundle.status),
    );
  }
}

/// What:   Summary block shared by the owner and provider bundle views.
/// Input:  [bundle]; [counts] such as "3 tasks".
/// Output: Counts, description, deadline text and status pill.
List<Widget> bundleSummary(
  BuildContext context,
  Bundle bundle, {
  required String counts,
}) {
  final theme = Theme.of(context);
  final muted = theme.colorScheme.onSurfaceVariant;
  final deadline = bundleDeadlineText(bundle);
  return [
    Text(counts, style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
    if (bundle.description.isNotEmpty) ...[
      const SizedBox(height: 8),
      Text(bundle.description, style: theme.textTheme.bodyMedium),
    ],
    if (deadline != null) ...[
      const SizedBox(height: 8),
      Text(deadline, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
    ],
    const SizedBox(height: 8),
    Align(
      alignment: Alignment.centerLeft,
      child: BundleStatusPill(bundle: bundle),
    ),
  ];
}
