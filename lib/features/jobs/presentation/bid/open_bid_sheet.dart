import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../auth/domain/app_user.dart';
import '../../data/bundle_bid_repository.dart';
import '../../data/bundle_repository.dart';
import '../../data/job_repository.dart';
import '../../domain/bundle.dart';
import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';
import 'submit_bid_sheet.dart';
import 'submit_bundle_bid_sheet.dart';

/// What:   Opens the bid sheet that fits [job].
/// Input:  [job] and [bidder] from the job detail or bundle screen.
/// Output: Package sheet for a live bundle task (rules refuse a per-job bid), else [SubmitBidSheet].
Future<void> openBidSheet(BuildContext context, Job job, AppUser bidder) async {
  if (!job.isLiveBundleTask) {
    SubmitBidSheet.show(context, job: job, bidder: bidder);
    return;
  }
  await openBundleBidSheet(context, job.bundleId!, bidder);
}

/// What:   Opens [SubmitBundleBidSheet] for [bundleId], prefilled with [bidder]'s bid if any.
/// Input:  Bundle, tasks and own bid read once, concurrently (bundle/job/bundle-bid repositories).
/// Output: The sheet, or a snackbar when bidding is closed, tasks are missing or a read fails.
Future<void> openBundleBidSheet(
  BuildContext context,
  String bundleId,
  AppUser bidder,
) async {
  void snack(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));
  try {
    // One await, so one mounted check covers every context use below.
    final results = await Future.wait<Object?>([
      context.read<BundleRepository>().getById(bundleId),
      context.read<JobRepository>().getBundleTasks(bundleId),
      context.read<BundleBidRepository>().getMyBundleBid(bundleId, bidder.uid),
    ]);
    if (!context.mounted) return;
    final bundle = results[0] as Bundle?;
    final tasks = results[1] as List<Job>;
    final existing = results[2] as BundleBid?;

    if (bundle == null || !bundle.biddingOpen) {
      snack('This bundle is no longer accepting bids.');
      return;
    }
    final taskIds = tasks.map((t) => t.id).toSet();
    if (!bundle.taskIds.every(taskIds.contains)) {
      snack(
        "Couldn't load every task in this bundle. Check your "
        'connection and try again.',
      );
      return;
    }
    SubmitBundleBidSheet.show(
      context,
      bundle: bundle,
      tasks: tasks,
      bidder: bidder,
      existing: existing,
    );
  } catch (_) {
    if (!context.mounted) return;
    snack("Couldn't open the bid form. Please try again.");
  }
}
