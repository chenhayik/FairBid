import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/util/money.dart';
import '../../../core/widgets/app_widgets.dart';
import '../data/stats_repository.dart';
import '../domain/platform_stats.dart';

/// Admin Home › Stats tab: the marketplace's headline numbers, loaded once
/// via aggregation queries with pull-to-refresh.
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

  Future<void> _refresh() async {
    final fresh = context.read<StatsRepository>().load();
    setState(() => _stats = fresh);
    await fresh;
  }

  /// Runs the idempotent server-side Trust Score backfill/repair (recounts
  /// completed jobs and lost disputes for every user).
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
            // Always scrollable so pull-to-refresh works even when short.
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(24),
            children: [
              Text('Platform Statistics',
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
                  label: 'Released Volume',
                  value: formatRm(stats.releasedVolumeSen),
                  icon: Icons.payments_outlined,
                ),
                const SizedBox(height: 12),
                _StatGrid(stats: stats),
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

/// Two-column grid of the count metrics.
class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.stats});

  final PlatformStats stats;

  @override
  Widget build(BuildContext context) {
    final cells = <(String, String, IconData)>[
      ('Clients', '${stats.requestors}', Icons.person_outline),
      ('Providers', '${stats.providers}', Icons.handyman_outlined),
      ('Open Jobs', '${stats.openJobs}', Icons.work_outline),
      ('In Progress', '${stats.inProgressJobs}', Icons.timelapse_outlined),
      ('Completed', '${stats.completedJobs}', Icons.task_alt_outlined),
      (
        'Pending Checks',
        '${stats.pendingVerifications}',
        Icons.verified_user_outlined
      ),
      ('Open Disputes', '${stats.openDisputes}', Icons.gavel_rounded),
      ('Total Users', '${stats.totalUsers}', Icons.groups_outlined),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.9,
      children: [
        for (final (label, value, icon) in cells)
          StatCard(label: label, value: value, icon: icon),
      ],
    );
  }
}
