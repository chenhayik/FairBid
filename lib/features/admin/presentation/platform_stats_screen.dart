import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/util/money.dart';
import '../../../core/widgets/app_widgets.dart';
import '../data/stats_repository.dart';
import '../domain/platform_stats.dart';

/// What:   Admin Stats tab with the marketplace's main numbers.
/// Input:  PlatformStats via StatsRepository.load() (stats_repository.dart), loaded once.
/// Output: Stat cards; pull to refresh; button to recompute Trust Scores.
class PlatformStatsScreen extends StatefulWidget {
  const PlatformStatsScreen({super.key});

  @override
  State<PlatformStatsScreen> createState() => _PlatformStatsScreenState();
}

class _PlatformStatsScreenState extends State<PlatformStatsScreen> {
  late Future<PlatformStats> _stats;
  bool _recomputing = false;

  @override
  void initState() {
    super.initState();
    _stats = context.read<StatsRepository>().load();
  }

  /// What:   Reloads the stats for pull-to-refresh.
  /// Input:  StatsRepository.load() (stats_repository.dart).
  /// Output: Replaces _stats and completes when the new load finishes.
  Future<void> _refresh() async {
    final fresh = context.read<StatsRepository>().load();
    setState(() {
      _stats = fresh;
    });
    await fresh;
  }

  /// What:   Recomputes every user's Trust Score.
  /// Input:  StatsRepository.recomputeTrustScores() (stats_repository.dart).
  /// Output: Snackbar with the user count or an error; the button shows "Recomputing…" meanwhile.
  Future<void> _recomputeTrust() async {
    setState(() => _recomputing = true);
    try {
      final users =
          await context.read<StatsRepository>().recomputeTrustScores();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Trust Scores recomputed for $users users.')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not recompute Trust Scores. Try again.')));
    } finally {
      if (mounted) setState(() => _recomputing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: _refresh,
      child: FutureBuilder<PlatformStats>(
        future: _stats,
        builder: (context, snapshot) {
          final stats = snapshot.data;
          return ListView(
            // Always scrollable so pull-to-refresh works on short pages.
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(24),
            children: [
              Text('Platform statistics',
                  style: theme.textTheme.headlineMedium),
              const SizedBox(height: 4),
              Text('A live snapshot of the marketplace. Pull to refresh.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 24),
              if (snapshot.hasError)
                const AppCard(
                  child: EmptyState(
                    icon: Icons.error_outline,
                    title: 'Couldn\'t load statistics',
                    message: 'Pull down to try again.',
                  ),
                )
              else if (stats == null)
                const Padding(
                  padding: EdgeInsets.only(top: 48),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                StatCard(
                  label: 'Released volume',
                  value: formatRm(stats.releasedVolumeSen),
                  icon: Icons.payments_outlined,
                ),
                const SizedBox(height: 12),
                _CardGrid(cells: [
                  ('Clients', formatCount(stats.requestors),
                      Icons.person_outline),
                  ('Providers', formatCount(stats.providers),
                      Icons.handyman_outlined),
                  ('Open jobs', formatCount(stats.openJobs),
                      Icons.work_outline),
                  ('In progress', formatCount(stats.inProgressJobs),
                      Icons.timelapse_outlined),
                  ('Completed', formatCount(stats.completedJobs),
                      Icons.task_alt_outlined),
                  ('Pending checks', formatCount(stats.pendingVerifications),
                      Icons.verified_user_outlined),
                  ('Open disputes', formatCount(stats.openDisputes),
                      Icons.gavel_rounded),
                  ('Total users', formatCount(stats.totalUsers),
                      Icons.groups_outlined),
                ]),
                const SizedBox(height: 24),
                Text('Bundles', style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                _CardGrid(cells: [
                  ('Bundles awarded', formatCount(stats.bundlesAwarded),
                      Icons.inventory_2_outlined),
                  (
                    'Split awards',
                    '${formatCount(stats.splitAwards)} '
                        '(${(stats.splitAwardRate * 100).toStringAsFixed(0)}%)',
                    Icons.call_split
                  ),
                ]),
                const SizedBox(height: 24),
                SecondaryButton(
                  label: _recomputing
                      ? 'Recomputing…'
                      : 'Recompute Trust Scores',
                  onPressed: _recomputing ? null : _recomputeTrust,
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// What:   Grid of stat cards, two per row.
/// Input:  [cells] as (label, value, icon) records.
/// Output: Rows of equal-height StatCards; a lone last card keeps its normal width.
class _CardGrid extends StatelessWidget {
  const _CardGrid({required this.cells});

  final List<(String, String, IconData)> cells;

  static const _columns = 2;
  static const _spacing = 12.0;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < cells.length; i += _columns) {
      final rowCells = cells.skip(i).take(_columns).toList();
      if (i > 0) rows.add(const SizedBox(height: _spacing));
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (j, (label, value, icon)) in rowCells.indexed) ...[
                if (j > 0) const SizedBox(width: _spacing),
                Expanded(
                  child: StatCard(label: label, value: value, icon: icon),
                ),
              ],
              // A lone last card keeps its normal width.
              if (rowCells.length < _columns) const Spacer(),
            ],
          ),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}
