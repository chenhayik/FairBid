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

/// Opens the right bid sheet for [job]: the bundle package sheet for a live
/// bundle task (rules refuse a per-job bid there), otherwise [SubmitBidSheet].
/// Shared by the job detail screen and the bundle screen.
Future<void> openBidSheet(BuildContext context, Job job, AppUser bidder) async {
  if (!job.isLiveBundleTask) {
    SubmitBidSheet.show(context, job: job, bidder: bidder);
    return;
  }
  await openBundleBidSheet(context, job.bundleId!, bidder);
}

/// Opens [SubmitBundleBidSheet] for [bundleId], prefilled with [bidder]'s
/// existing bid when they have one. Reads the bundle/tasks/bid one-shot and
/// concurrently, to avoid a partially-cached task list; failures are caught
/// here and shown as a snackbar.
Future<void> openBundleBidSheet(
  BuildContext context,
  String bundleId,
  AppUser bidder,
) async {
  try {
    // A single `Future.wait` keeps exactly one `await`/`context.mounted`
    // check before every `context` use below, satisfying the linter's gap check.
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This bundle is no longer accepting bids.'),
        ),
      );
      return;
    }
    final taskIds = tasks.map((t) => t.id).toSet();
    if (!bundle.taskIds.every(taskIds.contains)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Couldn't load every task in this bundle. Check your "
            'connection and try again.',
          ),
        ),
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Couldn't open the bid form. Please try again."),
      ),
    );
  }
}
