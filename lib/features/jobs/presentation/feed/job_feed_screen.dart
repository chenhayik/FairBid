import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../../../core/location/geo.dart';
import '../../../../core/location/region_picker_screen.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/money.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/keyed_stream_builder.dart';
import '../../../auth/presentation/auth_controller.dart';
import '../../../onboarding/presentation/steps/service_step.dart';
import '../../data/job_repository.dart';
import '../../domain/job.dart';
import '../widgets/job_card.dart';

/// Provider-facing browse screen: search + category/radius/budget filters over
/// the open-jobs stream, with client-side distance from the provider's saved
/// base location.
class JobFeedScreen extends StatefulWidget {
  const JobFeedScreen({super.key});

  @override
  State<JobFeedScreen> createState() => _JobFeedScreenState();
}

class _JobFeedScreenState extends State<JobFeedScreen> {
  final _search = TextEditingController();
  String? _category; // null = all
  int? _maxBudgetSen; // null = any
  double? _radiusKm; // null = any

  /// Debounces the search field. Every rebuild re-runs the whole filter pass
  /// (including a haversine per job) and, until the feed's stream is hoisted
  /// out of build(), also tears down and re-creates the Firestore listener -
  /// so typing "plumber" cost seven of each.
  Timer? _searchDebounce;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      const Duration(milliseconds: 300),
      () {
        if (mounted) setState(() {});
      },
    );
  }

  Future<void> _setBaseLocation() async {
    final picked = await RegionPickerScreen.show(context);
    if (picked == null || !mounted) return;
    await context.read<AuthController>().setBaseLocation(picked);
  }

  /// Applies the category, search, budget and radius filters and sorts by
  /// distance (nearest first) when a base location is known.
  List<(Job, String?)> _applyFilters(List<Job> jobs, LatLng? base) {
    final query = _search.text.trim().toLowerCase();
    final results = <(Job, double?)>[];
    for (final job in jobs) {
      if (_category != null && job.category != _category) continue;
      if (query.isNotEmpty &&
          !job.title.toLowerCase().contains(query) &&
          !job.description.toLowerCase().contains(query)) {
        continue;
      }
      final high = job.budget?.maxSen ?? job.budget?.minSen;
      if (_maxBudgetSen != null && high != null && high > _maxBudgetSen!) {
        continue;
      }
      double? km;
      if (base != null) {
        km = distanceKm(base, LatLng(job.location.lat, job.location.lng));
        if (_radiusKm != null && km > _radiusKm!) continue;
      }
      results.add((job, km));
    }
    results.sort((a, b) {
      if (a.$2 == null || b.$2 == null) return 0;
      return a.$2!.compareTo(b.$2!);
    });
    return [
      for (final (job, km) in results)
        (job, km == null ? null : formatDistance(km)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.read<JobRepository>();
    final user = context.watch<AuthController>().user;
    final base = user != null && user.hasBaseLocation
        ? LatLng(user.baseLat!, user.baseLng!)
        : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Find Jobs'),
        actions: [
          IconButton(
            tooltip: 'Saved Jobs',
            icon: const Icon(Icons.bookmark_border),
            onPressed: () => context.push('/jobs/saved'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: TextField(
                controller: _search,
                onChanged: _onSearchChanged,
                decoration: const InputDecoration(
                  hintText: 'Search for jobs...',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            _FilterBar(
              category: _category,
              radiusKm: _radiusKm,
              maxBudgetSen: _maxBudgetSen,
              onCategory: (v) => setState(() => _category = v),
              onRadius: (v) => setState(() => _radiusKm = v),
              onBudget: (v) => setState(() => _maxBudgetSen = v),
            ),
            if (base == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
                child: InfoBanner(
                  icon: Icons.my_location,
                  title: 'Set your location',
                  body: 'Add a base location to see distances and filter by '
                      'radius.',
                  trailing: TextButton(
                    onPressed: _setBaseLocation,
                    child: const Text('Set'),
                  ),
                ),
              ),
            Expanded(
              child: KeyedStreamBuilder<List<Job>>(
                create: repo.watchOpenJobs,
                builder: (context, snapshot) {
                  // hasData rather than the connection state: a resubscribe
                  // resets to `waiting` while retaining the previous results,
                  // and blanking the list in that case is what made searching
                  // and filtering feel broken.
                  if (!snapshot.hasData && !snapshot.hasError) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return const EmptyState(
                      icon: Icons.error_outline,
                      title: 'Could not load jobs',
                      message: 'Please check your connection and try again.',
                    );
                  }
                  final results = _applyFilters(snapshot.data ?? [], base);
                  if (results.isEmpty) {
                    return const EmptyState(
                      icon: Icons.search_off_rounded,
                      title: 'No jobs found',
                      message: 'Try widening your filters or check back later.',
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.all(24),
                    itemCount: results.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, i) {
                      final (job, distance) = results[i];
                      return JobCard(
                        job: job,
                        distanceLabel: distance,
                        onTap: () => context.push('/jobs/${job.id}'),
                        saved: user?.isSaved(job.id) ?? false,
                        onToggleSave: user == null
                            ? null
                            : () => context
                                .read<AuthController>()
                                .toggleSaved(job.id),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.category,
    required this.radiusKm,
    required this.maxBudgetSen,
    required this.onCategory,
    required this.onRadius,
    required this.onBudget,
  });

  final String? category;
  final double? radiusKm;
  final int? maxBudgetSen;
  final ValueChanged<String?> onCategory;
  final ValueChanged<double?> onRadius;
  final ValueChanged<int?> onBudget;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      child: Row(
        children: [
          _FilterChip<String?>(
            label: category ?? 'Category',
            value: category,
            items: {
              'All categories': null,
              for (final c in kServiceCategories) c: c,
            },
            onSelected: onCategory,
          ),
          const SizedBox(width: 8),
          _FilterChip<double?>(
            label: radiusKm == null ? 'Radius' : '${radiusKm!.round()} km',
            value: radiusKm,
            items: const {
              'Any distance': null,
              'Within 5 km': 5.0,
              'Within 10 km': 10.0,
              'Within 25 km': 25.0,
              'Within 50 km': 50.0,
            },
            onSelected: onRadius,
          ),
          const SizedBox(width: 8),
          _FilterChip<int?>(
            label: maxBudgetSen == null
                ? 'Budget'
                : '≤ ${formatRm(maxBudgetSen!)}',
            value: maxBudgetSen,
            items: const {
              'Any budget': null,
              'Up to RM 100': 10000,
              'Up to RM 500': 50000,
              'Up to RM 1,000': 100000,
              'Up to RM 5,000': 500000,
            },
            onSelected: onBudget,
          ),
        ],
      ),
    );
  }
}

/// Wraps a menu value so a `null` selection (e.g. the "All categories" reset,
/// whose value is `null`) isn't swallowed by [PopupMenuButton]'s `onCanceled`
/// path - a non-null wrapper is always distinguishable from a dismissed menu.
class _MenuOption<T> {
  const _MenuOption(this.value);
  final T value;
}

class _FilterChip<T> extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.value,
    required this.items,
    required this.onSelected,
  });

  final String label;
  final T value;
  final Map<String, T> items;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final active = value != null;

    return PopupMenuButton<_MenuOption<T>>(
      onSelected: (option) => onSelected(option.value),
      itemBuilder: (context) => [
        for (final entry in items.entries)
          PopupMenuItem(
            value: _MenuOption(entry.value),
            child: Text(entry.key),
          ),
      ],
      child: Chip(
        label: Text(label),
        avatar: const Icon(Icons.expand_more, size: 18),
        backgroundColor: active ? context.fairbid.subtleBlue : null,
      ),
    );
  }
}