import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../domain/bundle.dart';
import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';

/// Pill colour for a job status, shared by every job and task list.
Color jobStatusColor(BuildContext context, JobStatus status) =>
    switch (status) {
      JobStatus.open => context.fairbid.verified,
      JobStatus.inProgress => context.fairbid.warningText,
      JobStatus.completed => context.fairbid.successText,
      JobStatus.cancelled => Theme.of(context).colorScheme.onSurfaceVariant,
    };

/// Pill colour for a bundle status, matching [jobStatusColor].
Color bundleStatusColor(BuildContext context, BundleStatus status) =>
    switch (status) {
      BundleStatus.open => context.fairbid.verified,
      BundleStatus.awarded => context.fairbid.successText,
      BundleStatus.cancelled ||
      BundleStatus.expired => Theme.of(context).colorScheme.onSurfaceVariant,
    };

/// Pill colour for a provider's own bundle bid once the award has decided it
/// - accepted/partly accepted/rejected/closed - matching [jobStatusColor].
Color bundleBidStatusColor(BuildContext context, BundleBidStatus status) =>
    switch (status) {
      BundleBidStatus.accepted => context.fairbid.successText,
      BundleBidStatus.partlyAccepted => context.fairbid.warningText,
      BundleBidStatus.rejected => Theme.of(context).colorScheme.error,
      BundleBidStatus.pending => context.fairbid.warningText,
      BundleBidStatus.withdrawn ||
      BundleBidStatus.closed => Theme.of(context).colorScheme.onSurfaceVariant,
    };
