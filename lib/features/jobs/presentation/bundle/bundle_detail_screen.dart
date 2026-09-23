import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/money.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../data/bid_repository.dart';
import '../../data/bundle_bid_repository.dart';
import '../../data/bundle_repository.dart';
import '../../domain/bundle.dart';
import '../../domain/bundle_award.dart';
import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';
import '../../data/job_repository.dart';

/// The requestor's view of one bundled posting: its tasks, who bid on what,
/// and the three award options. Awarding happens here, in one action.
class BundleDetailScreen extends StatefulWidget {
  const BundleDetailScreen({super.key, required this.bundleId});

  final String bundleId;

  @override
  State<BundleDetailScreen> createState() => _BundleDetailScreenState();
}

class _BundleDetailScreenState extends State<BundleDetailScreen> {
  late final Stream<Bundle?> _bundle =
      context.read<BundleRepository>().watchBundle(widget.bundleId);
  late final Stream<List<Job>> _tasks =
      context.read<JobRepository>().watchBundleTasks(widget.bundleId);
  late final Stream<List<BundleBid>> _bids =
      context.read<BundleBidRepository>().watchBundleBids(widget.bundleId);

  /// Priced options from the server, or null until they are asked for.
  List<BundleAwardOption>? _options;
  bool _loadingOptions = false;
  bool _awarding = false;
  String? _error;

  Future<void> _loadOptions() async {
    setState(() {
      _loadingOptions = true;
      _error = null;
    });
    try {
      final options =
          await context.read<BundleRepository>().previewAward(widget.bundleId);
      if (mounted) setState(() => _options = options);
    } on BundleRejectedException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not load the award options.');
      }
    } finally {
      if (mounted) setState(() => _loadingOptions = false);
    }
  }

  Future<void> _award(BundleAwardOption option) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Award ${option.label.toLowerCase()}?'),
        content: Text(
          '${option.providerCount} provider(s) will be hired for '
          '${formatRm(option.totalSen)}, and that amount is locked in escrow '
          'now. Any task nobody won goes back to ordinary bidding.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Award'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _awarding = true;
      _error = null;
    });
    try {
      await context.read<BundleRepository>().award(
            bundleId: widget.bundleId,
            providerByTaskId: option.providerByTaskId,
            expectedTotalSen: option.totalSen,
          );
      if (!mounted) return;
      unawaited(HapticFeedback.mediumImpact());
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bundle awarded!')));
      context.pop();
    } on InsufficientBalanceException catch (e) {
      if (mounted) {
        setState(() => _error =
            'Your available balance is ${formatRm(e.availableSen)} but this '
            'award needs ${formatRm(e.requiredSen)}. Top up '
            '${formatRm(e.shortfallSen)} and try again.');
      }
    } on BundleRejectedException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not award this bundle.');
    } finally {
      if (mounted) setState(() => _awarding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Bundle?>(
      stream: _bundle,
      builder: (context, bundleSnap) {
        final bundle = bundleSnap.data;
        return Scaffold(
          appBar: AppBar(title: Text(bundle?.title ?? 'Bundle')),
          body: bundle == null
              ? const Center(child: CircularProgressIndicator())
              : SafeArea(child: _body(context, bundle)),
        );
      },
    );
  }

  Widget _body(BuildContext context, Bundle bundle) {
    final theme = Theme.of(context);
    return StreamBuilder<List<Job>>(
      stream: _tasks,
      builder: (context, taskSnap) {
        final tasks = taskSnap.data ?? const <Job>[];
        return StreamBuilder<List<BundleBid>>(
          stream: _bids,
          builder: (context, bidSnap) {
            final bids = bidSnap.data ?? const <BundleBid>[];
            return ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text('${bundle.taskCount} tasks  •  ${bids.length} bid(s)',
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 4),
                PillBadge(
                  label: bundle.status.label,
                  color: bundle.biddingOpen
                      ? context.fairbid.verified
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 20),
                if (_error != null) ErrorBanner(_error!),
                _TaskList(tasks: tasks, bids: bids),
                const SizedBox(height: 24),
                if (bundle.status == BundleStatus.open) ...[
                  Text('Award', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  if (bids.isEmpty)
                    Text('No bids yet.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant))
                  else if (_options == null)
                    PrimaryButton(
                      label: 'Show award options',
                      busy: _loadingOptions,
                      onPressed: _loadOptions,
                    )
                  else if (_options!.isEmpty)
                    Text('No bid covers any of these tasks yet.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant))
                  else
                    for (final option in _options!)
                      _OptionCard(
                        option: option,
                        tasks: tasks,
                        busy: _awarding,
                        onAward: () => _award(option),
                      ),
                ],
              ],
            );
          },
        );
      },
    );
  }
}

/// The tasks, each with what the bids offered for it.
class _TaskList extends StatelessWidget {
  const _TaskList({required this.tasks, required this.bids});

  final List<Job> tasks;
  final List<BundleBid> bids;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final task in tasks)
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(task.title, style: theme.textTheme.titleMedium),
                Text(task.category,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                for (final bid in bids.where((b) => b.coversTask(task.id)))
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '${bid.providerName}  ${formatRm(bid.priceFor(task.id)!)}'
                      '${bid.allOrNothing ? '  (all or nothing)' : ''}',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                if (!bids.any((b) => b.coversTask(task.id)))
                  Text('No bids on this task',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
      ],
    );
  }
}

/// One of the three options, with what it costs and who it hires.
class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.option,
    required this.tasks,
    required this.busy,
    required this.onAward,
  });

  final BundleAwardOption option;
  final List<Job> tasks;
  final bool busy;
  final VoidCallback onAward;

  String _titleFor(String taskId) {
    for (final task in tasks) {
      if (task.id == taskId) return task.title;
    }
    return 'a task';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(option.label,
                      style: theme.textTheme.titleMedium),
                ),
                Text(formatRm(option.totalSen),
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: context.fairbid.verified)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${option.providerCount} provider(s)'
              '${option.premiumSen > 0 ? '  •  ${formatRm(option.premiumSen)} more than the cheapest' : ''}'
              '  •  Trust ${option.weightedTrust}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            for (final award in option.awards)
              Text(
                '${award.providerName}: '
                '${award.taskAmountsSen.keys.map(_titleFor).join(', ')}'
                '  ${formatRm(award.totalSen)}',
                style: theme.textTheme.bodyMedium,
              ),
            if (option.uncoveredTaskIds.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Nobody bid on '
                  '${option.uncoveredTaskIds.map(_titleFor).join(', ')} - '
                  'awarding releases it back to ordinary bidding.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            for (final warning in option.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(warning,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: context.fairbid.warningText)),
              ),
            const SizedBox(height: 12),
            PrimaryButton(
              label: 'Award ${option.label.toLowerCase()}',
              busy: busy,
              onPressed: onAward,
            ),
          ],
        ),
      ),
    );
  }
}
