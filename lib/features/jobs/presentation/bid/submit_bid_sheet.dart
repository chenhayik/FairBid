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

/// Duration estimates a provider can pick when bidding.
const kBidDurations = [
  'Less than 1 day',
  '1–3 days',
  'Less than 1 week',
  '1–2 weeks',
  'More than 2 weeks',
];

/// Bottom sheet where a verified provider places a bid on [job].
class SubmitBidSheet extends StatelessWidget {
  const SubmitBidSheet({
    super.key,
    required this.job,
    required this.bidder,
    this.existing,
  });

  final Job job;
  final AppUser bidder;

  /// The provider's pending bid when editing; null for a new bid.
  final Bid? existing;

  /// Opens the sheet. Resolves once it closes (bid placed or dismissed).
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
  Widget build(BuildContext context) {
    return Padding(
      // Keep the form above the keyboard.
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _SubmitBidForm(job: job, bidder: bidder, existing: existing),
    );
  }
}

class _SubmitBidForm extends StatefulWidget {
  const _SubmitBidForm({
    required this.job,
    required this.bidder,
    required this.existing,
  });
  final Job job;
  final AppUser bidder;
  final Bid? existing;

  @override
  State<_SubmitBidForm> createState() => _SubmitBidFormState();
}

class _SubmitBidFormState extends State<_SubmitBidForm> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _message = TextEditingController();
  String? _duration;
  bool _escrowAcknowledged = false;

  /// Set when submit is blocked by the unticked escrow box. This used to be a
  /// snackbar, which anchors to the underlying route's Scaffold and therefore
  /// renders *behind* this bottom sheet: the provider tapped Submit, saw
  /// nothing at all happen, and abandoned their only revenue action.
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

  Future<void> _submit() async {
    // Evaluate both gates before returning so the field errors and the escrow
    // error appear together, rather than the user fixing one and discovering
    // the other.
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
      // Fire-and-forget: awaiting a haptic would put an async gap in front of
      // the pop below, leaving the sheet up for an extra frame.
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
      padding: const EdgeInsets.all(24),
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
            Text('Estimated duration', style: theme.textTheme.labelLarge),
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
              label: 'Proposal message',
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
                'I understand the client pays the full price into escrow '
                'when they hire me, and FairBid releases it to me when they '
                'approve the work.',
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
