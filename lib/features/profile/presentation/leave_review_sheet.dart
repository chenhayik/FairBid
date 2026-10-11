import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/form_widgets.dart';
import '../../auth/domain/app_user.dart';
import '../../jobs/domain/job.dart';
import '../data/review_repository.dart';
import '../domain/review.dart';

/// What:   Bottom sheet where one party reviews the other after a completed [job]: 1-5 stars plus an optional comment.
/// Input:  [job], [reviewer], [revieweeId], [revieweeName], optional [bundleId]; ReviewRepository.leaveReview().
/// Output: [show] resolves `true` once a review exists; a Cloud Function then recomputes the reviewee's Trust Score.
class LeaveReviewSheet extends StatefulWidget {
  const LeaveReviewSheet({
    super.key,
    required this.job,
    required this.reviewer,
    required this.revieweeId,
    required this.revieweeName,
    this.bundleId,
  });

  final Job job;
  final AppUser reviewer;
  final String revieweeId;
  final String revieweeName;

  /// The bundle to key the review by when [job] is a live bundle task; else keyed by job id.
  final String? bundleId;

  static Future<bool?> show(
    BuildContext context, {
    required Job job,
    required AppUser reviewer,
    required String revieweeId,
    required String revieweeName,
    String? bundleId,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => LeaveReviewSheet(
        job: job,
        reviewer: reviewer,
        revieweeId: revieweeId,
        revieweeName: revieweeName,
        bundleId: bundleId,
      ),
    );
  }

  @override
  State<LeaveReviewSheet> createState() => _LeaveReviewSheetState();
}

class _LeaveReviewSheetState extends State<LeaveReviewSheet> {
  final _comment = TextEditingController();
  int _rating = 0;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_rating == 0) {
      setState(() => _error = 'Please select a star rating.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final review = Review(
      id: '', // The repository derives the doc id.
      reviewerId: widget.reviewer.uid,
      reviewerName: widget.reviewer.displayName ?? 'User',
      reviewerPhotoUrl: widget.reviewer.profilePhotoUrl,
      rating: _rating,
      comment: _comment.text.trim(),
      jobId: widget.job.id,
      jobTitle: widget.job.title,
    );
    try {
      await context.read<ReviewRepository>().leaveReview(
            revieweeId: widget.revieweeId,
            review: review,
            bundleId: widget.bundleId,
          );
      unawaited(HapticFeedback.mediumImpact());
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ReviewAlreadyExistsException {
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('You have already reviewed this job.')));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not submit your review. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Leave a Review', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 4),
            Text(
              'How was working with ${widget.revieweeName}?',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            if (_error != null) ErrorBanner(_error!),
            Center(child: _StarSelector(
              rating: _rating,
              onChanged: (r) => setState(() {
                _rating = r;
                _error = null;
              }),
            )),
            const SizedBox(height: 20),
            AppTextField(
              controller: _comment,
              label: 'Comment (optional)',
              hint: 'Share how it went: quality, communication, timeliness…',
              maxLines: 4,
            ),
            const SizedBox(height: 8),
            PrimaryButton(
              label: 'Submit Review',
              busy: _busy,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

/// Tappable row of five stars.
class _StarSelector extends StatelessWidget {
  const _StarSelector({required this.rating, required this.onChanged});

  final int rating;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final gold = context.fairbid.warningText;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          IconButton(
            onPressed: () => onChanged(i),
            iconSize: 40,
            icon: Icon(
              i <= rating ? Icons.star_rounded : Icons.star_border_rounded,
              color: gold,
            ),
          ),
      ],
    );
  }
}
