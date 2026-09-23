import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../../core/config/platform_config.dart';
import '../../../../core/util/money.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/form_widgets.dart';
import '../../../auth/domain/app_user.dart';
import '../../../auth/presentation/validators.dart';
import '../../data/bundle_bid_repository.dart';
import '../../domain/bundle.dart';
import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';
import 'submit_bid_sheet.dart' show kBidDurations;
import 'submit_bundle_bid_controller.dart';

/// Bottom sheet where a verified provider places (or edits) a package bid on
/// [bundle]'s [tasks]. Mirrors `SubmitBidSheet`'s shape, but a provider picks
/// a subset of tasks first, prices each one, and may add a discounted bundle
/// price for winning all of them.
class SubmitBundleBidSheet extends StatelessWidget {
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

  /// The provider's current bid on this bundle, when they're editing one -
  /// prefills every field. Null when placing a first bid.
  final BundleBid? existing;

  /// Opens the sheet. Resolves once it closes (bid placed, updated,
  /// withdrawn or dismissed).
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
  Widget build(BuildContext context) {
    return Padding(
      // Keep the form above the keyboard.
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _SubmitBundleBidForm(
        bundle: bundle,
        tasks: tasks,
        bidder: bidder,
        existing: existing,
      ),
    );
  }
}

class _SubmitBundleBidForm extends StatefulWidget {
  const _SubmitBundleBidForm({
    required this.bundle,
    required this.tasks,
    required this.bidder,
    required this.existing,
  });

  final Bundle bundle;
  final List<Job> tasks;
  final AppUser bidder;
  final BundleBid? existing;

  @override
  State<_SubmitBundleBidForm> createState() => _SubmitBundleBidFormState();
}

class _SubmitBundleBidFormState extends State<_SubmitBundleBidForm> {
  final _formKey = GlobalKey<FormState>();

  /// Ticked state per task id, in [widget.tasks] order.
  late final Map<String, bool> _ticked;

  /// "Price if you get only this task" controller per task id.
  late final Map<String, TextEditingController> _prices;
  final _bundlePrice = TextEditingController();
  final _message = TextEditingController();
  bool _allOrNothing = false;
  String? _duration;
  bool _escrowAcknowledged = false;

  /// Set when submit is blocked by the unticked escrow box. This used to be a
  /// snackbar, which anchors to the underlying route's Scaffold and therefore
  /// renders *behind* this bottom sheet: the provider tapped Submit, saw
  /// nothing at all happen, and abandoned their only revenue action.
  bool _showEscrowError = false;

  /// Set when submit is attempted with no task ticked.
  bool _showNoTaskError = false;

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
      }
      _allOrNothing = existing.allOrNothing;
      // Defends against a duration that no longer matches kBidDurations
      // (e.g. the list changes later) rather than crashing the dropdown.
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

  /// The other tasks sharing [task]'s lot, or empty when it isn't in one.
  List<Job> _lotPartners(Job task) {
    final lotId = task.lotId;
    if (lotId == null) return const [];
    return widget.tasks
        .where((t) => t.lotId == lotId && t.id != task.id)
        .toList();
  }

  /// Ticks or unticks [task] - and, when it shares a lot with other tasks,
  /// every task in that lot with it, since a lot can't be split between
  /// bids. The server re-checks this; this is just so the provider doesn't
  /// submit a doomed bid.
  void _toggleTask(Job task, bool? value) {
    final tick = value ?? false;
    setState(() {
      final lotId = task.lotId;
      if (lotId == null) {
        _ticked[task.id] = tick;
      } else {
        for (final t in widget.tasks) {
          if (t.lotId == lotId) _ticked[t.id] = tick;
        }
      }
      if (tick) _showNoTaskError = false;
    });
  }

  List<Job> get _tickedTasks =>
      widget.tasks.where((t) => _ticked[t.id] == true).toList();

  int get _tickedTaskTotalSen => _tickedTasks.fold(
        0,
        (sum, t) => sum + (parseRmToSen(_prices[t.id]!.text) ?? 0),
      );

  Future<void> _submit() async {
    final tickedTasks = _tickedTasks;
    // Evaluate every gate before returning so the field errors, the no-task
    // error and the escrow error all appear together, rather than the
    // provider fixing one and discovering the next.
    final formValid = _formKey.currentState!.validate();
    setState(() {
      _showNoTaskError = tickedTasks.isEmpty;
      _showEscrowError = !_escrowAcknowledged;
    });
    if (tickedTasks.isEmpty || !formValid || !_escrowAcknowledged) return;

    final controller = context.read<SubmitBundleBidController>();
    final bundlePriceText = _bundlePrice.text.trim();
    final ok = await controller.submit(
      bundleId: widget.bundle.id,
      taskPrices: {
        for (final t in tickedTasks) t.id: parseRmToSen(_prices[t.id]!.text)!,
      },
      bundlePriceSen:
          bundlePriceText.isEmpty ? null : parseRmToSen(bundlePriceText),
      allOrNothing: _allOrNothing,
      estimatedDuration: _duration!,
      message: _message.text.trim(),
    );
    if (ok && mounted) {
      // Fire-and-forget: awaiting a haptic would put an async gap in front of
      // the pop below, leaving the sheet up for an extra frame.
      unawaited(HapticFeedback.mediumImpact());
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text(_isUpdate ? 'Bundle bid updated!' : 'Bundle bid submitted!'),
      ));
    }
  }

  Future<void> _withdraw() async {
    final controller = context.read<SubmitBundleBidController>();
    final ok = await controller.withdraw(widget.bundle.id);
    if (ok && mounted) {
      unawaited(HapticFeedback.mediumImpact());
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Bundle bid withdrawn.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = context.watch<SubmitBundleBidController>();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
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
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              '${widget.tasks.length} tasks • pick the ones you can do',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            InfoBanner(
              icon: Icons.info_outline,
              title: 'Bidding on more tasks helps you win',
              body: 'The requestor is shown the option with the fewest '
                  'providers whenever it costs at most '
                  '${PlatformConfig.consolidationCapPct}% and '
                  '${formatRm(PlatformConfig.consolidationCapSen)} more than '
                  'the cheapest total - so covering more of these tasks can '
                  'win you the whole bundle.',
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
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            AppTextField(
              controller: _bundlePrice,
              label: 'Bundle price (RM)',
              hint: '0.00',
              prefixText: 'RM ',
              helperText: 'Charged only if you win every task you picked',
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              validator: (v) {
                final text = v?.trim() ?? '';
                if (text.isEmpty) return null;
                final sen = parseRmToSen(text);
                if (sen == null || sen <= 0) {
                  return 'Amount must be more than RM 0.';
                }
                final total = _tickedTaskTotalSen;
                if (sen >= total) {
                  return 'Must be lower than your task prices added up '
                      '(${formatRm(total)}).';
                }
                return null;
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _allOrNothing,
              onChanged: (v) => setState(() => _allOrNothing = v),
              title: const Text('All or nothing'),
              subtitle: const Text(
                'Award me all the tasks I picked, or none of them.',
              ),
            ),
            const SizedBox(height: 8),
            Text('Estimated Duration', style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: _duration,
              hint: const Text('How long will it take?'),
              items: [
                for (final d in kBidDurations)
                  DropdownMenuItem(value: d, child: Text(d)),
              ],
              onChanged: (v) => setState(() => _duration = v),
              validator: (v) => v == null ? 'Pick a duration.' : null,
            ),
            const SizedBox(height: 16),
            AppTextField(
              controller: _message,
              label: 'Proposal Message',
              hint: 'Explain your approach, experience and what\'s included...',
              maxLines: 4,
              validator: (v) => Validators.required(v, 'Message'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _escrowAcknowledged,
              onChanged: (v) => setState(() {
                _escrowAcknowledged = v ?? false;
                if (_escrowAcknowledged) _showEscrowError = false;
              }),
              title: Text(
                'I understand FairBid uses milestone escrow: the client '
                'funds the job and payment is released as work is approved. '
                'Your money is held by FairBid, not paid out, until the '
                'client approves the work.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            if (_showEscrowError)
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 4),
                child: Text(
                  'Please tick this to confirm you understand, then submit.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 8),
            PrimaryButton(
              label: _isUpdate ? 'Update Bundle Bid' : 'Submit Bundle Bid',
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

  /// One task's row: a checkbox with its title/category, an optional lot
  /// note, and - only while ticked - its price field.
  Widget _taskRow(ThemeData theme, Job task) {
    final ticked = _ticked[task.id] ?? false;
    final lotPartners = _lotPartners(task);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: ticked,
          onChanged: (v) => _toggleTask(task, v),
          title: Text(task.title),
          subtitle: Text(task.category),
        ),
        if (lotPartners.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Text(
              'Bid together with ${lotPartners.map((t) => t.title).join(', ')}'
              ' - splitting this group between providers isn\'t allowed.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              validator: (v) {
                final sen = parseRmToSen(v);
                if (sen == null) return 'Enter a price for this task.';
                if (sen <= 0) return 'Amount must be more than RM 0.';
                return null;
              },
            ),
          ),
      ],
    );
  }
}
