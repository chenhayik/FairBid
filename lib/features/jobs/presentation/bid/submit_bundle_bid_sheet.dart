import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../../core/config/platform_config.dart';
import '../../../../core/util/money.dart';
import '../../../../core/util/service_categories.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/form_widgets.dart';
import '../../../auth/domain/app_user.dart';
import '../../data/bundle_bid_repository.dart';
import '../../domain/bundle.dart';
import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';
import 'submit_bid_sheet.dart' show BidTermsFields, kBidDurations;
import 'submit_bundle_bid_controller.dart';

/// What:   Bottom sheet for a provider to place or edit a package bid on [bundle].
/// Input:  [bundle], [tasks], [bidder]; [existing] when editing; a SubmitBundleBidController from [show].
/// Output: Pick tasks, price each, optional package price; submit/withdraw via BundleBidRepository.
class SubmitBundleBidSheet extends StatefulWidget {
  const SubmitBundleBidSheet({
    super.key,
    required this.bundle,
    required this.tasks,
    required this.bidder,
    this.existing,
  });

  final Bundle bundle;
  final List<Job> tasks;
  final AppUser bidder;
  final BundleBid? existing;

  static Future<void> show(
    BuildContext context, {
    required Bundle bundle,
    required List<Job> tasks,
    required AppUser bidder,
    BundleBid? existing,
  }) {
    final bundleBids = context.read<BundleBidRepository>();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ChangeNotifierProvider(
        create: (_) => SubmitBundleBidController(bundleBids),
        child: SubmitBundleBidSheet(
          bundle: bundle,
          tasks: tasks,
          bidder: bidder,
          existing: existing,
        ),
      ),
    );
  }

  @override
  State<SubmitBundleBidSheet> createState() => _SubmitBundleBidSheetState();
}

class _SubmitBundleBidSheetState extends State<SubmitBundleBidSheet> {
  final _formKey = GlobalKey<FormState>();

  late final Map<String, bool> _ticked;

  /// "Price if you get only this task" per task id.
  late final Map<String, TextEditingController> _prices;
  final _bundlePrice = TextEditingController();
  final _message = TextEditingController();
  bool _showBundlePrice = false;
  String? _duration;
  bool _escrowAcknowledged = false;

  /// Shown in the sheet because a snackbar would appear behind it.
  bool _showEscrowError = false;

  bool _showNoTaskError = false;

  final _expandedDescriptions = <String>{};

  bool get _isUpdate => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _ticked = {
      for (final task in widget.tasks)
        task.id: existing?.coversTask(task.id) ?? false,
    };
    _prices = {
      for (final task in widget.tasks)
        task.id: TextEditingController(
          text: switch (existing?.priceFor(task.id)) {
            null => '',
            final sen => (sen / 100).toStringAsFixed(2),
          },
        ),
    };
    if (existing != null) {
      final bundlePriceSen = existing.bundlePriceSen;
      if (bundlePriceSen != null) {
        _bundlePrice.text = (bundlePriceSen / 100).toStringAsFixed(2);
        _showBundlePrice = true;
      }
      // A stored duration may no longer be in kBidDurations.
      _duration = kBidDurations.contains(existing.estimatedDuration)
          ? existing.estimatedDuration
          : null;
      _message.text = existing.message;
    }
  }

  @override
  void dispose() {
    for (final controller in _prices.values) {
      controller.dispose();
    }
    _bundlePrice.dispose();
    _message.dispose();
    super.dispose();
  }

  void _toggleTask(Job task, bool? value) {
    final tick = value ?? false;
    setState(() {
      _ticked[task.id] = tick;
      if (tick) _showNoTaskError = false;
      // Below two tasks, clear and hide the bundle price.
      if (!_bundleFieldsEnabled) {
        _bundlePrice.clear();
        _showBundlePrice = false;
      }
    });
  }

  List<Job> get _tickedTasks =>
      widget.tasks.where((t) => _ticked[t.id] == true).toList();

  int get _tickedTaskTotalSen => _tickedTasks.fold(
    0,
    (sum, t) => sum + (parseRmToSen(_prices[t.id]!.text) ?? 0),
  );

  bool get _bundleFieldsEnabled => _tickedTasks.length >= 2;

  /// "RM X off your task total" while the bundle price is valid.
  String _bundleSavingText() {
    final sen = parseRmToSen(_bundlePrice.text);
    final total = _tickedTaskTotalSen;
    if (sen == null || sen <= 0 || sen >= total) {
      return 'Charged only if you win every task you picked';
    }
    return '${formatRm(total - sen)} off your task total';
  }

  Future<void> _submit() async {
    final tickedTasks = _tickedTasks;
    // Check every gate so all errors show together.
    final formValid = _formKey.currentState!.validate();
    setState(() {
      _showNoTaskError = tickedTasks.isEmpty;
      _showEscrowError = !_escrowAcknowledged;
    });
    if (tickedTasks.isEmpty || !formValid || !_escrowAcknowledged) return;

    final bundlePriceText = _bundlePrice.text.trim();
    final totalSen = parseRmToSen(bundlePriceText) ?? _tickedTaskTotalSen;
    if (totalSen > PlatformConfig.maxBidSen) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Your bid total can't be more than RM 50,000."),
      ));
      return;
    }

    final controller = context.read<SubmitBundleBidController>();
    final ok = await controller.submit(
      bundleId: widget.bundle.id,
      taskPrices: {
        for (final t in tickedTasks) t.id: parseRmToSen(_prices[t.id]!.text)!,
      },
      bundlePriceSen: bundlePriceText.isEmpty
          ? null
          : parseRmToSen(bundlePriceText),
      estimatedDuration: _duration!,
      message: _message.text.trim(),
    );
    if (ok && mounted) {
      // Not awaited, so the sheet doesn't stay up an extra frame.
      unawaited(HapticFeedback.mediumImpact());
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isUpdate ? 'Bundle bid updated!' : 'Bundle bid submitted!',
          ),
        ),
      );
    }
  }

  Future<void> _withdraw() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Withdraw your bundle bid?',
      body: 'You\'ll no longer be considered for any of its tasks.',
      actionLabel: 'Withdraw',
    );
    if (!confirmed || !mounted) return;
    final controller = context.read<SubmitBundleBidController>();
    final ok = await controller.withdraw(widget.bundle.id);
    if (ok && mounted) {
      unawaited(HapticFeedback.mediumImpact());
      Navigator.of(context).pop();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Bundle bid withdrawn.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = context.watch<SubmitBundleBidController>();

    return SingleChildScrollView(
      // Keeps the form above the keyboard.
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Bid on this bundle', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 4),
            Text(
              widget.bundle.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${widget.tasks.length} tasks • pick the ones you can do',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Tip: covering more tasks can win you the whole bundle.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            if (controller.errorMessage != null)
              ErrorBanner(controller.errorMessage!),
            for (final task in widget.tasks) _taskRow(theme, task),
            if (_showNoTaskError)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  'Pick at least one task to bid on.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            if (_bundleFieldsEnabled && !_showBundlePrice)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _showBundlePrice = true),
                  child: const Text('+ Add a package deal (optional)'),
                ),
              ),
            if (_bundleFieldsEnabled && _showBundlePrice)
              ListenableBuilder(
                // Rebuilds the saving line as the prices change.
                listenable: Listenable.merge([
                  _bundlePrice,
                  ..._prices.values,
                ]),
                builder: (context, _) => AppTextField(
                  controller: _bundlePrice,
                  label: 'Price if you win all ${_tickedTasks.length} tasks (RM)',
                  hint: '0.00',
                  prefixText: 'RM ',
                  helperText: _bundleSavingText(),
                  labelTrailing: TextButton(
                    onPressed: () => setState(() {
                      _bundlePrice.clear();
                      _showBundlePrice = false;
                    }),
                    child: const Text('Remove'),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: (v) {
                    final text = v?.trim() ?? '';
                    if (text.isEmpty) return null;
                    final sen = parseRmToSen(text);
                    if (sen == null || sen <= 0) {
                      return 'Amount must be more than RM 0.';
                    }
                    if (sen > PlatformConfig.maxBidSen) {
                      return "A bundle price can't be more than RM 50,000.";
                    }
                    final total = _tickedTaskTotalSen;
                    if (sen >= total) {
                      return 'Must be under ${formatRm(total)} (your task total).';
                    }
                    return null;
                  },
                ),
              ),
            const SizedBox(height: 8),
            BidTermsFields(
              duration: _duration,
              onDurationChanged: (v) => setState(() => _duration = v),
              message: _message,
              escrowAcknowledged: _escrowAcknowledged,
              showEscrowError: _showEscrowError,
              onEscrowChanged: (v) => setState(() {
                _escrowAcknowledged = v;
                if (v) _showEscrowError = false;
              }),
            ),
            // Repeated: the sheet is tall, so the top error may be off screen.
            if (controller.errorMessage != null) ...[
              const SizedBox(height: 8),
              ErrorBanner(controller.errorMessage!),
            ],
            const SizedBox(height: 8),
            PrimaryButton(
              label: _isUpdate ? 'Update bundle bid' : 'Submit bundle bid',
              busy: controller.isBusy,
              onPressed: _submit,
            ),
            if (_isUpdate) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: controller.isBusy ? null : _withdraw,
                child: const Text('Withdraw bid'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _taskRow(ThemeData theme, Job task) {
    final ticked = _ticked[task.id] ?? false;
    final budgetLabel = task.budget?.label;
    final expanded = _expandedDescriptions.contains(task.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: ticked,
          onChanged: (v) => _toggleTask(task, v),
          title: Text(task.title),
          subtitle: Text(
            budgetLabel == null
                ? task.category
                : '${task.category} • $budgetLabel',
          ),
        ),
        if (task.description.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => setState(() {
                  if (expanded) {
                    _expandedDescriptions.remove(task.id);
                  } else {
                    _expandedDescriptions.add(task.id);
                  }
                }),
                child: Text(expanded ? 'Hide details' : 'Show details'),
              ),
            ),
          ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8, right: 4),
            child: Text(task.description, style: theme.textTheme.bodySmall),
          ),
        if (licenceNoticeFor(task.category) != null)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Text(
              licenceNoticeFor(task.category)!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (ticked)
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 4),
            child: AppTextField(
              controller: _prices[task.id]!,
              label: 'Price if you get only this task (RM)',
              hint: '0.00',
              prefixText: 'RM ',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              validator: (v) {
                final sen = parseRmToSen(v);
                if (sen == null) return 'Enter a price for this task.';
                if (sen <= 0) return 'Amount must be more than RM 0.';
                if (sen > PlatformConfig.maxBidSen) {
                  return "A task price can't be more than RM 50,000.";
                }
                return null;
              },
            ),
          ),
      ],
    );
  }
}
