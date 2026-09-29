import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/widgets/app_widgets.dart';
import '../../domain/bundle.dart';
import '../widgets/status_colors.dart';

/// "Bidding closes 1 Oct 2026" / "Bidding closed 1 Oct 2026" for a still-open
/// bundle with a deadline, else null (once awarded, cancelled or expired the
/// status pill says it all). Shared by the owner and provider views.
String? bundleDeadlineText(Bundle bundle) {
  if (bundle.status != BundleStatus.open || bundle.deadline == null) {
    return null;
  }
  final date = DateFormat.yMMMd().format(bundle.deadline!);
  return bundle.biddingOpen ? 'Bidding closes $date' : 'Bidding closed $date';
}

/// The bundle's status pill. Reads "Closed" rather than "Open" once the
/// deadline has passed but the bundle hasn't been awarded/cancelled/expired.
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
