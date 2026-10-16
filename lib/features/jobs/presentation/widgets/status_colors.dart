import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../domain/bundle.dart';
import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';

/// What:   Pill colour for a job status.
/// Input:  [status].
/// Output: Blue open, amber in progress, green completed, grey cancelled.
Color jobStatusColor(BuildContext context, JobStatus status) =>
    switch (status) {
      JobStatus.open => context.fairbid.verified,
      JobStatus.inProgress => context.fairbid.warningText,
      JobStatus.completed => context.fairbid.successText,
      JobStatus.cancelled => Theme.of(context).colorScheme.onSurfaceVariant,
    };

/// What:   Pill colour for a bundle status.
/// Input:  [status].
/// Output: Blue open, green awarded, grey cancelled or expired.
Color bundleStatusColor(BuildContext context, BundleStatus status) =>
    switch (status) {
      BundleStatus.open => context.fairbid.verified,
      BundleStatus.awarded => context.fairbid.successText,
      BundleStatus.cancelled ||
      BundleStatus.expired => Theme.of(context).colorScheme.onSurfaceVariant,
    };

/// What:   Pill colour for a package bid status.
/// Input:  [status].
/// Output: Green accepted, amber pending or partly accepted, red rejected, grey withdrawn or closed.
Color bundleBidStatusColor(BuildContext context, BundleBidStatus status) =>
    switch (status) {
      BundleBidStatus.accepted => context.fairbid.successText,
      BundleBidStatus.partlyAccepted => context.fairbid.warningText,
      BundleBidStatus.rejected => Theme.of(context).colorScheme.error,
      BundleBidStatus.pending => context.fairbid.warningText,
      BundleBidStatus.withdrawn ||
      BundleBidStatus.closed => Theme.of(context).colorScheme.onSurfaceVariant,
    };
