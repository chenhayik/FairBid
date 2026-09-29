import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/money.dart';
import '../../../../core/util/plural.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../auth/presentation/auth_controller.dart';
import '../../data/bid_repository.dart';
import '../../data/bundle_bid_repository.dart';
import '../../data/bundle_repository.dart';
import '../../data/job_repository.dart';
import '../../domain/bundle.dart';
import '../../domain/bundle_award.dart';
import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';
import '../widgets/insufficient_balance_dialog.dart';
import 'bundle_bid_list.dart';
import 'bundle_buttons.dart';
import 'bundle_header.dart';
import 'bundle_manual_award_section.dart';
import 'bundle_option_card.dart';
import 'bundle_provider_view.dart';
import 'bundle_task_section.dart';
import 'bundle_warning_banner.dart';

/// One bundled posting. The client sees its tasks, who bid on what, and the
/// award options (awarding happens here, in one action); anyone else sees the
/// read-only [BundleProviderView].
class BundleDetailScreen extends StatefulWidget {
  const BundleDetailScreen({
    super.key,
    required this.bundleId,
    this.fromTaskId,
  });

  final String bundleId;

  /// The task this screen was opened from, if any: tapping that task goes
  /// back to it instead of stacking another copy on the back stack.
  final String? fromTaskId;

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
  // Owner only (rules deny everyone else) - and lazy, so only the owner's
  // view ever subscribes.
  late final Stream<List<BundleBid>> _bids = context
      .read<BundleBidRepository>()
      .watchBundleBids(widget.bundleId);

  /// The viewer's own bid, for the provider view. Lazy, like [_bids].
  late final Stream<BundleBid?> _myBid = context
      .read<BundleBidRepository>()
      .watchMyBundleBid(
        widget.bundleId,
        context.read<AuthController>().user!.uid,
      );

  /// Priced options from the server, or null until they are asked for.
  List<BundleAwardOption>? _options;
  bool _loadingOptions = false;
  bool _awarding = false;
  bool _cancelling = false;
  String? _error;

  /// The bids [_options] were priced from (see [_bidsSignature]), so a live
  /// bids list that has since moved on can be noticed and offered a refresh.
  String? _optionsSignature;

  /// The client's own picks for the manual matrix: task id -> provider id,
  /// or null for "don't award". Starts with every task unpicked.
  final Map<String, String?> _picks = {};

  /// The manual pick's own priced option, or null until "Check price" is
  /// pressed - priced on demand rather than eagerly with the automatic
  /// options.
  BundleAwardOption? _manualOption;
  List<String> _manualProblems = const [];
  bool _pricingManual = false;

  /// A cheap fingerprint of [bids]: who bid, their status, when they last
  /// changed it and what they're charging - sorted so it doesn't depend on
  /// the stream's delivery order. Two calls with the same bids produce the
  /// same signature; any change to any bid (including an edit, which keeps
  /// `createdAt` but bumps `updatedAt` and the prices) changes it.
  String _bidsSignature(List<BundleBid> bids) {
    String pricesOf(BundleBid bid) {
      final entries = bid.taskPrices.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      return entries.map((e) => '${e.key}=${e.value}').join(',');
    }

    final parts = [
      for (final bid in bids)
        '${bid.providerId}:${bid.status.storage}:'
            '${bid.createdAt?.millisecondsSinceEpoch}:'
            '${bid.updatedAt?.millisecondsSinceEpoch}:'
            '${bid.bundlePriceSen}:${pricesOf(bid)}',
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

  /// Confirms and cancels the whole bundle (and its still-open tasks) through
  /// `cancelBundle`. Available to the owner any time the bundle is still
  /// open, whether or not bidding has closed - it's the only way to call the
  /// posting off before it's awarded.
  Future<void> _cancelBundle() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel this bundle?'),
        content: const Text(
          "This also cancels its still-open tasks. Providers who've "
          "already bid will be notified. This can't be undone.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.fairbid.danger,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel bundle'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _cancelling = true;
      _error = null;
    });
    try {
      await context.read<BundleRepository>().cancelBundle(widget.bundleId);
    } on BundleRejectedException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not cancel the bundle. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  /// Confirms and sends the award. When [option] leaves tasks uncovered, the
  /// confirmation also collects the deadline those tasks are released back
  /// to ordinary bidding with - defaulting to 7 days out, changeable via the
  /// same date picker `post_job_screen`'s deadline field uses.
  Future<void> _award(BundleAwardOption option, List<Job> tasks) async {
    String titleFor(String taskId) {
      for (final task in tasks) {
        if (task.id == taskId) return task.title;
      }
      return 'a task';
    }

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
          title: const Text('Award this option?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                option.label,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${plural(option.providerCount, 'provider')} will be hired '
                'for ${formatRm(option.totalSen)}, and that amount is '
                'locked in escrow now.',
              ),
              if (option.uncoveredTaskIds.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '${plural(option.uncoveredTaskIds.length, 'task')} will '
                  'be released back to ordinary bidding: '
                  '${option.uncoveredTaskIds.map(titleFor).join(', ')}.',
                ),
              ],
              if (releasedDeadline != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Released back until '
                        '${DateFormat.yMMMd().format(releasedDeadline!)}.',
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
      // "Show award options" instead of leaving the client stuck.
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

  /// Opens [task]'s job detail - or, when this screen was opened from that
  /// task, goes back to it instead of stacking another copy.
  void _openTask(Job task) {
    if (task.id == widget.fromTaskId && context.canPop()) {
      context.pop();
    } else {
      context.push('/jobs/${task.id}?from=bundle');
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthController>().user;
    return StreamBuilder<Bundle?>(
      stream: _bundle,
      builder: (context, bundleSnap) {
        final bundle = bundleSnap.data;
        if (bundle != null && me != null && me.uid != bundle.requestorId) {
          return BundleProviderView(
            bundle: bundle,
            tasks: _tasks,
            myBid: _myBid,
            me: me,
            onOpenTask: _openTask,
          );
        }
        return Scaffold(
          appBar: AppBar(title: Text(bundle?.title ?? 'Bundle')),
          // Wait for the viewer too: owner or not decides what to subscribe to.
          body: bundle == null || me == null
              ? const Center(child: CircularProgressIndicator())
              : SafeArea(child: _body(context, bundle)),
        );
      },
    );
  }

  Widget _body(BuildContext context, Bundle bundle) {
    final theme = Theme.of(context);
    final deadline = bundleDeadlineText(bundle);

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
                  '${plural(bundle.taskCount, 'task')}  •  '
                  '${plural(bids.length, 'bid')}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (bundle.description.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(bundle.description, style: theme.textTheme.bodyMedium),
                ],
                if (deadline != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    deadline,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: BundleStatusPill(bundle: bundle),
                ),
                if (bundle.status == BundleStatus.open) ...[
                  const SizedBox(height: 12),
                  OutlinedBusyButton(
                    label: 'Cancel bundle',
                    busy: _cancelling,
                    onPressed: _cancelBundle,
                  ),
                ],
                const SizedBox(height: 20),
                if (_error != null) ErrorBanner(_error!),
                if (bundle.status == BundleStatus.open)
                  BundleOpenTaskList(
                    tasks: tasks,
                    bids: bids,
                    onOpenTask: _openTask,
                  )
                else
                  BundleTaskStatusList(tasks: tasks, onOpenTask: _openTask),
                if (bids.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  BundleBidList(bids: bids, tasks: tasks),
                ],
                if (bundle.status == BundleStatus.open) ...[
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
                          child: WarningBanner(
                            'The bids have changed since these options were '
                            'worked out. Refresh before awarding.',
                            trailing: TextButton(
                              onPressed: () => _loadOptions(bids),
                              child: const Text('Refresh'),
                            ),
                          ),
                        ),
                      for (final merged in mergeBundleOptions(_options!))
                        BundleOptionCard(
                          merged: merged,
                          tasks: tasks,
                          primary: merged.isRecommended,
                          busy: _awarding,
                          enabled: _optionsSignature == _bidsSignature(bids),
                          onAward: () => _award(merged.option, tasks),
                        ),
                    ],
                    const SizedBox(height: 24),
                    BundleManualAwardSection(
                      tasks: tasks,
                      bids: bids,
                      picks: _picks,
                      onPick: _onPick,
                      onCheckPrice: _checkManualPrice,
                      busy: _pricingManual,
                      option: _manualOption,
                      problems: _manualProblems,
                      awarding: _awarding,
                      onAward: (option) => _award(option, tasks),
                    ),
                  ] else
                    Text(
                      'Bidding closed on '
                      '${DateFormat.yMMMd().format(bundle.deadline!)}. This '
                      'bundle can no longer be awarded.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
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
