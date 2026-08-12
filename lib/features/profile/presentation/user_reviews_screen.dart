import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/app_widgets.dart';
import '../data/review_repository.dart';
import '../domain/review.dart';
import 'widgets/review_card.dart';

/// The "See all N reviews" screen opened from [PublicProfileScreen] - pushed
/// full-screen with a back button. Pages of ~20 reviews at a time (newest
/// first, loaded as the list scrolls near the end); no sort control and no
/// ratings-distribution histogram (misleading under ~5 reviews, which is
/// most profiles at launch).
class UserReviewsScreen extends StatefulWidget {
  const UserReviewsScreen({super.key, required this.uid});

  final String uid;

  @override
  State<UserReviewsScreen> createState() => _UserReviewsScreenState();
}

class _UserReviewsScreenState extends State<UserReviewsScreen> {
  static const _pageSize = 20;

  final _reviews = <Review>[];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _loadFirstPage();
  }

  Future<void> _loadFirstPage() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final page = await context.read<ReviewRepository>().fetchReviewPage(
        widget.uid,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _reviews
          ..clear()
          ..addAll(page);
        _hasMore = page.length == _pageSize;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _reviews.isEmpty) return;
    final cursor = _reviews.last.createdAt;
    if (cursor == null) {
      // No timestamp to page from (shouldn't happen on a saved review) -
      // stop rather than risk re-fetching the same page forever.
      setState(() => _hasMore = false);
      return;
    }
    setState(() => _loadingMore = true);
    try {
      final page = await context.read<ReviewRepository>().fetchReviewPage(
        widget.uid,
        limit: _pageSize,
        startAfter: cursor,
      );
      if (!mounted) return;
      setState(() {
        _reviews.addAll(page);
        _hasMore = page.length == _pageSize;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not load more reviews. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reviews')),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error) {
      return const EmptyState(
        icon: Icons.error_outline,
        title: "Couldn't load reviews",
        message: 'Please check your connection and try again.',
      );
    }
    if (_reviews.isEmpty) {
      return const EmptyState(
        icon: Icons.star_border_rounded,
        title: 'No reviews yet',
        message: 'Reviews from completed jobs will appear here.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(24),
      itemCount: _reviews.length + (_hasMore ? 1 : 0),
      separatorBuilder: (_, _) => const Divider(height: 24),
      itemBuilder: (context, i) {
        if (i >= _reviews.length) {
          // Building this trailing slot means the list has scrolled near the
          // end - kick off the next page. Guarded by _loadingMore/_hasMore,
          // so a rebuild of this same slot while a fetch is in flight is a
          // no-op.
          WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return ReviewCard(review: _reviews[i], onFlag: null);
      },
    );
  }
}
