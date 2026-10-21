import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

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
import '../widgets/deadline_picker.dart';
import '../widgets/insufficient_balance_dialog.dart';
import 'bundle_bid_list.dart';
import 'bundle_header.dart';
import 'bundle_option_card.dart';
import 'bundle_pick_bar.dart';
import 'bundle_pick_section.dart';
import 'bundle_provider_view.dart';
import 'bundle_pick_logic.dart';
import 'bundle_task_section.dart';
import 'bundle_warning_banner.dart';

/// What:   Bundle detail screen.
/// Input:  Bundle, tasks and bids via BundleRepository / JobRepository / BundleBidRepository streams.
/// Output: Owner: tasks, bids, award options and award/cancel. Anyone else: [BundleProviderView].
class BundleDetailScreen extends StatefulWidget {
  const BundleDetailScreen({
    super.key,
    required this.bundleId,
    this.fromTaskId,
  });

  final String bundleId;

  /// Tapping this task pops back to it instead of stacking another copy.
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
  // Owner only (rules deny others); lazy, so only the owner's view subscribes.
  late final Stream<List<BundleBid>> _bids = context
      .read<BundleBidRepository>()
      .watchBundleBids(widget.bundleId);

  /// Lazy, like [_bids].
  late final Stream<BundleBid?> _myBid = context
      .read<BundleBidRepository>()
      .watchMyBundleBid(
        widget.bundleId,
        context.read<AuthController>().user!.uid,
      );

  /// Null until requested.
  List<BundleAwardOption>? _options;
  bool _loadingOptions = false;
  bool _awarding = false;
  bool _cancelling = false;
  String? _error;

  /// Signature of the bids [_options] were priced from; a mismatch offers a refresh.
  String? _optionsSignature;

  /// Task id -> provider id, or null for "don't award".
  final Map<String, String?> _picks = {};

  /// The picks priced by `priceManualAward`; null while pricing or refused.
  BundleAwardOption? _manualOption;
  List<String> _manualProblems = const [];
  bool _pricingManual = false;

  String? _manualSignature;

  /// Counts pricing calls so a slow, older answer can't overwrite a newer one.
  int _pricingRun = 0;

  /// What:   Fingerprint of the current bids.
  /// Input:  [bids] from BundleBidRepository.watchBundleBids().
  /// Output: Order-independent string; any edit (new updatedAt or prices) changes it, so stale options and picks are detectable.
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

  /// What:   Loads the server's award options.
  /// Input:  BundleRepository.previewAward(bundleId) (bundle_repository.dart); [bids] only for the freshness signature.
  /// Output: Sets [_options] and [_optionsSignature], or [_error].
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

  /// What:   Records the client's pick for one task.
  /// Output: Updates [_picks] and re-prices them.
  void _onPick(String taskId, String? providerId, List<BundleBid> bids) {
    setState(() => _picks[taskId] = providerId);
    _priceManual(bids);
  }

  /// What:   Copies an award option into the manual picks.
  /// Output: Replaces [_picks] with the option's providers and re-prices them.
  void _useOption(BundleAwardOption option, List<BundleBid> bids) {
    setState(() {
      _picks
        ..clear()
        ..addAll(option.providerByTaskId);
    });
    _priceManual(bids);
  }

  /// What:   Prices the manual picks on the server.
  /// Input:  [_picks] via BundleRepository.priceManualAward() (bundle_repository.dart).
  /// Output: Sets [_manualOption] or [_manualProblems].
  /// Notes:  [_pricingRun] drops a slow, older answer that would overwrite a newer one.
  Future<void> _priceManual(List<BundleBid> bids) async {
    final picks = {
      for (final entry in _picks.entries)
        if (entry.value != null) entry.key: entry.value!,
    };
    final run = ++_pricingRun;
    setState(() {
      _pricingManual = picks.isNotEmpty;
      _manualOption = null;
      _manualProblems = const [];
      _manualSignature = _bidsSignature(bids);
    });
    if (picks.isEmpty) return;
    try {
      final result = await context.read<BundleRepository>().priceManualAward(
        widget.bundleId,
        picks,
      );
      if (!mounted || run != _pricingRun) return;
      setState(() {
        _manualOption = result.option;
        _manualProblems = result.problems;
      });
    } on BundleRejectedException catch (e) {
      if (mounted && run == _pricingRun) {
        setState(() => _manualProblems = [e.message]);
      }
    } catch (_) {
      if (mounted && run == _pricingRun) {
        setState(() => _manualProblems = ['Could not price your pick.']);
      }
    } finally {
      if (mounted && run == _pricingRun) {
        setState(() => _pricingManual = false);
      }
    }
  }

  /// What:   Cancel-bundle button handler.
  /// Output: After a confirm dialog, cancels the whole bundle and its open tasks via BundleRepository.cancelBundle().
  Future<void> _cancelBundle() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Cancel this bundle?',
      body: "This also cancels its still-open tasks. Providers who've "
          "already bid will be notified. This can't be undone.",
      cancelLabel: 'Keep it',
      actionLabel: 'Cancel bundle',
      danger: true,
    );
    if (!confirmed || !mounted) return;

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
        setState(
          () => _error = 'Could not cancel the bundle. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  /// What:   Award button handler for one option.
  /// Input:  [option] (server-priced) and [tasks] for titles.
  /// Output: After a confirm dialog, awards via BundleRepository.award(); success pops with a snackbar, a balance shortfall opens the top-up dialog.
  /// Notes:  For uncovered tasks the dialog asks to release them to ordinary bidding (deadline defaults to 7 days) or drop them.
  Future<void> _award(BundleAwardOption option, List<Job> tasks) async {
    String titleFor(String taskId) => taskTitle(tasks, taskId);

    DateTime? releasedDeadline;
    var dropUnawarded = false;
    if (option.uncoveredTaskIds.isNotEmpty) {
      releasedDeadline = endOfDay(DateTime.now().add(const Duration(days: 7)));
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
                  'Not awarded: '
                  '${option.uncoveredTaskIds.map(titleFor).join(', ')}.',
                ),
                const SizedBox(height: 8),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text('Post separately')),
                    ButtonSegment(value: true, label: Text('Drop')),
                  ],
                  selected: {dropUnawarded},
                  onSelectionChanged: (s) =>
                      setDialogState(() => dropUnawarded = s.first),
                ),
                if (dropUnawarded) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${option.uncoveredTaskIds.length == 1 ? 'It' : 'They'} '
                    'will be cancelled.',
                  ),
                ],
              ],
              if (releasedDeadline != null && !dropUnawarded) ...[
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
                        final picked = await pickBiddingDeadline(
                          context,
                          initial: releasedDeadline,
                        );
                        if (picked == null) return;
                        setDialogState(() => releasedDeadline = picked);
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
    // Clear busy before reporting, or the button spins behind the dialog.
    Object? failure;
    try {
      await context.read<BundleRepository>().award(
        bundleId: widget.bundleId,
        providerByTaskId: option.providerByTaskId,
        expectedTotalSen: option.totalSen,
        releasedDeadline: dropUnawarded ? null : releasedDeadline,
        dropUnawarded: dropUnawarded,
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
      // Stale options are likeliest; clearing them brings back "Show award options".
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

  /// What:   Opens a task's job detail.
  /// Output: Pops back if it is [fromTaskId], else pushes `/jobs/{id}?from=bundle`.
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

  /// What:   Owner view body.
  /// Input:  Task and bid streams ([_tasks], [_bids]).
  /// Output: Summary, tasks, bids, award options and manual picks, with the pick bar when picking.
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
            final awardable =
                bundle.status == BundleStatus.open && bundle.biddingOpen;
            final picking = awardable && bids.isNotEmpty;
            final hasPick = _picks.values.any((v) => v != null);
            final optionsFresh = _optionsSignature == _bidsSignature(bids);
            final list = ListView(
              padding: const EdgeInsets.all(24),
              children: [
                ...bundleSummary(
                  context,
                  bundle,
                  counts: '${plural(bundle.taskCount, 'task')}  •  '
                      '${plural(bids.length, 'bid')}',
                ),
                if (bids.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: () =>
                        showBundleBids(context, bids: bids, tasks: tasks),
                    icon: const Icon(Icons.gavel_rounded),
                    label: Text('View all bids (${bids.length})'),
                  ),
                ],
                if (bundle.status == BundleStatus.open) ...[
                  const SizedBox(height: 12),
                  SecondaryButton(
                    label: 'Cancel bundle',
                    busy: _cancelling,
                    onPressed: _cancelBundle,
                  ),
                ],
                const SizedBox(height: 20),
                if (_error != null) ErrorBanner(_error!),
                if (!awardable) ...[
                  if (bundle.status == BundleStatus.open)
                    BundleTaskList(tasks: tasks, onOpenTask: _openTask)
                  else
                    BundleTaskStatusList(
                      tasks: tasks,
                      bids: bids,
                      onOpenTask: _openTask,
                    ),
                  if (bundle.status == BundleStatus.open) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Bidding closed on '
                      '${DateFormat.yMMMd().format(bundle.deadline!)}. This '
                      'bundle can no longer be awarded.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ] else ...[
                  Text(
                    'Compare award options',
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Each option covers as many tasks as the bids allow. '
                    'Compare total price, number of providers and Trust '
                    'Score.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
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
                    if (!optionsFresh)
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
                        primary: merged.isBestValue,
                        busy: _awarding,
                        enabled: optionsFresh,
                        onAward: () => _award(merged.option, tasks),
                        onUse: () => _useOption(merged.option, bids),
                      ),
                  ],
                  const SizedBox(height: 24),
                  if (picking)
                    BundlePickSection(
                      tasks: tasks,
                      bids: bids,
                      picks: _picks,
                      onPick: (taskId, id) => _onPick(taskId, id, bids),
                      onOpenTask: _openTask,
                    )
                  else
                    BundleTaskList(tasks: tasks, onOpenTask: _openTask),
                ],
              ],
            );
            if (!(picking && hasPick)) return list;
            // Keeps the priced pick in view while scrolling.
            return Column(
              children: [
                Expanded(child: list),
                BundlePickBar(
                  option: _manualOption,
                  problems: _manualProblems,
                  pricing: _pricingManual,
                  stale: _manualSignature != _bidsSignature(bids),
                  awarding: _awarding,
                  onRefresh: () => _priceManual(bids),
                  onAward: () => _award(_manualOption!, tasks),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
