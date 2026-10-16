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
import '../../data/bid_repository.dart';
import '../../domain/bid.dart';
import '../../domain/job.dart';
import 'submit_bid_controller.dart';

const kBidDurations = [
  'Less than 1 day',
  '1–3 days',
  'Less than 1 week',
  '1–2 weeks',
  'More than 2 weeks',
];

/// What:   Bottom sheet where a verified provider places or edits a bid on [job].
/// Input:  [job], [bidder]; [existing] when editing; a SubmitBidController from [show].
/// Output: Calls BidRepository.submitBid() via the controller; pops and shows a snackbar on success.
class SubmitBidSheet extends StatefulWidget {
  const SubmitBidSheet({
    super.key,
    required this.job,
    required this.bidder,
    this.existing,
  });

  final Job job;
  final AppUser bidder;
  final Bid? existing;

  /// What:   Opens the sheet as a modal bottom sheet.
  /// Input:  [job], [bidder], optional [existing] bid; BidRepository via context.read.
  /// Output: Future that completes when the sheet closes.
  static Future<void> show(BuildContext context,
      {required Job job, required AppUser bidder, Bid? existing}) {
    final bids = context.read<BidRepository>();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ChangeNotifierProvider(
        create: (_) => SubmitBidController(bids),
        child: SubmitBidSheet(job: job, bidder: bidder, existing: existing),
      ),
    );
  }

  @override
  State<SubmitBidSheet> createState() => _SubmitBidSheetState();
}

class _SubmitBidSheetState extends State<SubmitBidSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _message = TextEditingController();
  String? _duration;
  bool _escrowAcknowledged = false;

  /// Set when submit is blocked by the unticked escrow box. Shown in the
  /// sheet because a snackbar would render behind it.
  bool _showEscrowError = false;

  bool get _isUpdate => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing == null) return;
    _amount.text = (existing.amountSen / 100).toStringAsFixed(2);
    _duration = kBidDurations.contains(existing.estimatedDuration)
        ? existing.estimatedDuration
        : null;
    _message.text = existing.message;
  }

  @override
  void dispose() {
    _amount.dispose();
    _message.dispose();
    super.dispose();
  }

  /// What:   Submit button handler.
  /// Output: Validates the form and the escrow checkbox together; on success pops with a snackbar.
  Future<void> _submit() async {
    // Check both gates so all errors show together.
    final formValid = _formKey.currentState!.validate();
    setState(() => _showEscrowError = !_escrowAcknowledged);
    if (!formValid || !_escrowAcknowledged) return;
    final controller = context.read<SubmitBidController>();
    final ok = await controller.submit(Bid(
      jobId: widget.job.id,
      providerId: widget.bidder.uid,
      providerName: widget.bidder.displayName ?? 'Provider',
      providerPhotoUrl: widget.bidder.profilePhotoUrl,
      providerTrustScore: widget.bidder.trustScore,
      providerScoreVisible: widget.bidder.scoreVisible,
      amountSen: parseRmToSen(_amount.text)!,
      estimatedDuration: _duration!,
      message: _message.text.trim(),
    ));
    if (ok && mounted) {
      // Not awaited, so the sheet doesn't stay up an extra frame.
      unawaited(HapticFeedback.mediumImpact());
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_isUpdate ? 'Bid updated!' : 'Bid submitted!')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = context.watch<SubmitBidController>();

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
            Text(_isUpdate ? 'Edit your bid' : 'Submit a bid', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 4),
            Text(
              widget.job.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            if (controller.errorMessage != null)
              ErrorBanner(controller.errorMessage!),
            AppTextField(
              controller: _amount,
              label: 'Your bid (RM)',
              hint: '0.00',
              prefixText: 'RM ',
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              validator: (v) {
                final sen = parseRmToSen(v);
                if (sen == null) return 'Enter your bid amount.';
                if (sen <= 0) return 'Amount must be more than RM 0.';
                if (sen > PlatformConfig.maxBidSen) {
                  return "A bid can't be more than RM 50,000.";
                }
                return null;
              },
            ),
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
            const SizedBox(height: 8),
            PrimaryButton(
              label: _isUpdate ? 'Update bid' : 'Submit bid',
              busy: controller.isBusy,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

/// What:   The duration, message and escrow-acknowledgement fields of a bid.
/// Input:  State held by the parent sheet (single-job or bundle bid).
/// Output: Rendered fields; changes go back through the callbacks.
class BidTermsFields extends StatelessWidget {
  const BidTermsFields({
    super.key,
    required this.duration,
    required this.onDurationChanged,
    required this.message,
    required this.escrowAcknowledged,
    required this.showEscrowError,
    required this.onEscrowChanged,
  });

  final String? duration;
  final ValueChanged<String?> onDurationChanged;
  final TextEditingController message;
  final bool escrowAcknowledged;
  final bool showEscrowError;
  final ValueChanged<bool> onEscrowChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Estimated duration', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          initialValue: duration,
          hint: const Text('How long will it take?'),
          items: [
            for (final d in kBidDurations)
              DropdownMenuItem(value: d, child: Text(d)),
          ],
          onChanged: onDurationChanged,
          validator: (v) => v == null ? 'Pick a duration.' : null,
        ),
        const SizedBox(height: 16),
        AppTextField(
          controller: message,
          label: 'Proposal message',
          hint: 'Explain your approach, experience and what\'s included...',
          maxLines: 4,
          validator: (v) => Validators.required(v, 'Message'),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: escrowAcknowledged,
          onChanged: (v) => onEscrowChanged(v ?? false),
          title: Text(
            'I understand the client pays the full price into escrow '
            'when they hire me, and FairBid releases it to me when they '
            'approve the work.',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        if (showEscrowError)
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 4),
            child: Text(
              'Please tick this to confirm you understand, then submit.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}
