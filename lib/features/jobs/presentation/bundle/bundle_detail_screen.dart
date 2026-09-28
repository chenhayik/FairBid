import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
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
import '../widgets/insufficient_balance_dialog.dart';

/// The requestor's view of one bundled posting: its tasks, who bid on what,
/// and the three award options. Awarding happens here, in one action.
class BundleDetailScreen extends StatefulWidget {
  const BundleDetailScreen({super.key, required this.bundleId});

  final String bundleId;

  @override
  State<BundleDetailScreen> createState() => _BundleDetailScreenState();
}

class _BundleDetailScreenState extends State<BundleDetailScreen> {
  late final Stream<Bundle?> _bundle = context
      .read<BundleRepository>()
      .watchBundle(widget.bundleId);
  late final Stream<List<Job>> _tasks = context
      .read<JobRepository>()
      .watchBundleTasks(widget.bundleId);
  late final Stream<List<BundleBid>> _bids = context
      .read<BundleBidRepository>()
      .watchBundleBids(widget.bundleId);

  /// Priced options from the server, or null until they are asked for.
  List<BundleAwardOption>? _options;
  bool _loadingOptions = false;
  bool _awarding = false;
  String? _error;

  /// The bids [_options] were priced from (see [_bidsSignature]), so a live
  /// bids list that has since moved on can be noticed and offered a refresh.
  String? _optionsSignature;

  /// The requestor's own picks for the manual matrix: task id -> provider
  /// id, or null for "don't award". Starts with every task unpicked.
  final Map<String, String?> _picks = {};

  /// The manual pick's own priced option, or null until "Check price" is
  /// pressed - priced on demand rather than eagerly with the three
  /// automatic options.
  BundleAwardOption? _manualOption;
  List<String> _manualProblems = const [];
  bool _pricingManual = false;

  /// A cheap fingerprint of [bids]: who bid, their status and when, sorted so
  /// it doesn't depend on the stream's delivery order. Two calls with the
  /// same bids produce the same signature; any change to any bid changes it.
  String _bidsSignature(List<BundleBid> bids) {
    final parts = [
      for (final bid in bids)
        '${bid.providerId}:${bid.status.storage}:'
            '${bid.createdAt?.millisecondsSinceEpoch}',
    ]..sort();
    return parts.join('|');
  }

  Future<void> _loadOptions(List<BundleBid> bids) async {
    setState(() {
      _loadingOptions = true;
      _error = null;
    });
    try {
      final options = await context.read<BundleRepository>().previewAward(
        widget.bundleId,
      );
      if (mounted) {
        setState(() {
          _options = options;
          _optionsSignature = _bidsSignature(bids);
        });
      }
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

  /// Records [providerId] as the pick for [taskId] (or clears it) and drops
  /// any previously priced manual result - it no longer matches the matrix.
  void _onPick(String taskId, String? providerId) {
    setState(() {
      _picks[taskId] = providerId;
      _manualOption = null;
      _manualProblems = const [];
    });
  }

  /// Prices the current picks through `previewBundleAward`.
  Future<void> _checkManualPrice() async {
    final picks = {
      for (final entry in _picks.entries)
        if (entry.value != null) entry.key: entry.value!,
    };
    setState(() {
      _pricingManual = true;
      _manualOption = null;
      _manualProblems = const [];
    });
    try {
      final result = await context.read<BundleRepository>().priceManualAward(
        widget.bundleId,
        picks,
      );
      if (!mounted) return;
      setState(() {
        _manualOption = result.option;
        _manualProblems = result.problems;
      });
    } on BundleRejectedException catch (e) {
      if (mounted) setState(() => _manualProblems = [e.message]);
    } catch (_) {
      if (mounted) {
        setState(() => _manualProblems = ['Could not price your pick.']);
      }
    } finally {
      if (mounted) setState(() => _pricingManual = false);
    }
  }

  /// Confirms and sends the award. When [option] leaves tasks uncovered, the
  /// confirmation also collects the deadline those tasks are released back
  /// to ordinary bidding with - defaulting to 7 days out, changeable via the
  /// same date picker `post_job_screen`'s deadline field uses.
  Future<void> _award(BundleAwardOption option) async {
    DateTime? releasedDeadline;
    if (option.uncoveredTaskIds.isNotEmpty) {
      final defaultDate = DateTime.now().add(const Duration(days: 7));
      releasedDeadline = DateTime(
        defaultDate.year,
        defaultDate.month,
        defaultDate.day,
        23,
        59,
        59,
      );
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Award ${option.label.toLowerCase()}?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${option.providerCount} provider(s) will be hired for '
                '${formatRm(option.totalSen)}, and that amount is locked in '
                'escrow now.',
              ),
              if (releasedDeadline != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Tasks nobody wins go back to ordinary bidding '
                        'until ${DateFormat.yMMMd().format(releasedDeadline!)}.',
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        final tomorrow = DateTime.now().add(
                          const Duration(days: 1),
                        );
                        final firstDate = DateTime(
                          tomorrow.year,
                          tomorrow.month,
                          tomorrow.day,
                        );
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: releasedDeadline!,
                          firstDate: firstDate,
                          lastDate: firstDate.add(const Duration(days: 90)),
                        );
                        if (picked == null) return;
                        setDialogState(
                          () => releasedDeadline = DateTime(
                            picked.year,
                            picked.month,
                            picked.day,
                            23,
                            59,
                            59,
                          ),
                        );
                      },
                      child: const Text('Change'),
                    ),
                  ],
                ),
              ],
            ],
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
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _awarding = true;
      _error = null;
    });
    // Capture the outcome, then clear busy state *before* reporting it -
    // otherwise the Award button spins behind the insufficient-balance dialog.
    Object? failure;
    try {
      await context.read<BundleRepository>().award(
        bundleId: widget.bundleId,
        providerByTaskId: option.providerByTaskId,
        expectedTotalSen: option.totalSen,
        releasedDeadline: releasedDeadline,
      );
    } catch (error) {
      failure = error;
    }
    if (!mounted) return;
    setState(() => _awarding = false);

    if (failure == null) {
      unawaited(HapticFeedback.mediumImpact());
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Bundle awarded!')));
      context.pop();
      return;
    }
    if (failure is InsufficientBalanceException) {
      await showInsufficientBalanceDialog(context, failure);
    } else if (failure is BundleRejectedException) {
      // Stale options are the likeliest cause - clearing them brings back
      // "Show award options" instead of leaving the requestor stuck.
      final message = failure.message;
      setState(() {
        _error = message;
        _options = null;
        _optionsSignature = null;
      });
    } else {
      setState(() => _error = 'Could not award this bundle.');
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
                Text(
                  '${bundle.taskCount} tasks  •  ${bids.length} bid(s)',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
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
                if (bundle.biddingOpen) ...[
                  Text('Award', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  if (bids.isEmpty)
                    Text(
                      'No bids yet.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    )
                  else if (_options == null)
                    PrimaryButton(
                      label: 'Show award options',
                      busy: _loadingOptions,
                      onPressed: () => _loadOptions(bids),
                    )
                  else if (_options!.isEmpty)
                    Text(
                      'No bid covers any of these tasks yet.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    )
                  else ...[
                    if (_optionsSignature != _bidsSignature(bids))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'The bids have changed since these options '
                                'were worked out.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: context.fairbid.warningText,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () => _loadOptions(bids),
                              child: const Text('Refresh'),
                            ),
                          ],
                        ),
                      ),
                    for (final option in _options!)
                      _OptionCard(
                        option: option,
                        tasks: tasks,
                        busy: _awarding,
                        onAward: () => _award(option),
                      ),
                  ],
                  const SizedBox(height: 24),
                  _ManualAwardSection(
                    tasks: tasks,
                    bids: bids,
                    picks: _picks,
                    onPick: _onPick,
                    onCheckPrice: _checkManualPrice,
                    busy: _pricingManual,
                    option: _manualOption,
                    problems: _manualProblems,
                    awarding: _awarding,
                    onAward: _award,
                  ),
                ] else if (bundle.status == BundleStatus.open)
                  Text(
                    'Bidding closed on '
                    '${DateFormat.yMMMd().format(bundle.deadline!)}. This '
                    'bundle can no longer be awarded; you can still cancel '
                    'it.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
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
                Text(
                  task.category,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
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
                  Text(
                    'No bids on this task',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
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
    // The cheapest option's own total (totalSen - premiumSen), so the
    // premium can also be shown as a percentage of it.
    final cheapestSen = option.totalSen - option.premiumSen;
    final premiumPct = option.premiumSen > 0 && cheapestSen > 0
        ? option.premiumSen * 100 / cheapestSen
        : 0.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(option.label, style: theme.textTheme.titleMedium),
                ),
                Text(
                  formatRm(option.totalSen),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: context.fairbid.verified,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${option.providerCount} provider(s)'
              '${option.premiumSen > 0 ? '  •  ${formatRm(option.premiumSen)} '
                        '(${premiumPct.toStringAsFixed(1)}%) more than the '
                        'cheapest' : ''}'
              '  •  Trust ${option.weightedTrust}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
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
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            for (final warning in option.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  warning,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: context.fairbid.warningText,
                  ),
                ),
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

/// The requestor's own pick matrix: one dropdown per task, then a button to
/// price the pick through the same shape the three automatic options use.
class _ManualAwardSection extends StatelessWidget {
  const _ManualAwardSection({
    required this.tasks,
    required this.bids,
    required this.picks,
    required this.onPick,
    required this.onCheckPrice,
    required this.busy,
    required this.option,
    required this.problems,
    required this.awarding,
    required this.onAward,
  });

  final List<Job> tasks;
  final List<BundleBid> bids;
  final Map<String, String?> picks;
  final void Function(String taskId, String? providerId) onPick;
  final VoidCallback onCheckPrice;
  final bool busy;
  final BundleAwardOption? option;
  final List<String> problems;
  final bool awarding;
  final void Function(BundleAwardOption) onAward;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Pick providers yourself', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        for (final task in tasks)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: DropdownButtonFormField<String?>(
              isExpanded: true,
              initialValue: picks[task.id],
              decoration: InputDecoration(
                labelText: 'Pick for "${task.title}"',
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text("Don't award")),
                for (final bid in bids.where((b) => b.coversTask(task.id)))
                  DropdownMenuItem(
                    value: bid.providerId,
                    child: Text(
                      '${bid.providerName} · '
                      '${formatRm(bid.priceFor(task.id)!)}',
                    ),
                  ),
              ],
              onChanged: (value) => onPick(task.id, value),
            ),
          ),
        PrimaryButton(
          label: 'Check price',
          busy: busy,
          onPressed: onCheckPrice,
        ),
        if (problems.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: ErrorBanner(problems.join('\n')),
          ),
        if (option != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _OptionCard(
              option: option!,
              tasks: tasks,
              busy: awarding,
              onAward: () => onAward(option!),
            ),
          ),
      ],
    );
  }
}
