import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
  const SubmitBidSheet({super.key, required this.job, required this.bidder});

  final Job job;
  final AppUser bidder;

  /// Opens the sheet. Resolves once it closes (bid placed or dismissed).
  static Future<void> show(BuildContext context,
      {required Job job, required AppUser bidder}) {
    final bids = context.read<BidRepository>();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ChangeNotifierProvider(
        create: (_) => SubmitBidController(bids),
        child: SubmitBidSheet(job: job, bidder: bidder),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Keep the form above the keyboard.
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _SubmitBidForm(job: job, bidder: bidder),
    );
  }
}

class _SubmitBidForm extends StatefulWidget {
  const _SubmitBidForm({required this.job, required this.bidder});
  final Job job;
  final AppUser bidder;

  @override
  State<_SubmitBidForm> createState() => _SubmitBidFormState();
}

class _SubmitBidFormState extends State<_SubmitBidForm> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _message = TextEditingController();
  String? _duration;
  bool _escrowAcknowledged = false;

  @override
  void dispose() {
    _amount.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_escrowAcknowledged) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please acknowledge the escrow terms.')));
      return;
    }
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
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bid submitted!')));
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
            Text('Submit a Bid', style: theme.textTheme.headlineMedium),
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
              label: 'Your Bid (RM)',
              hint: '0.00',
              prefixText: 'RM ',
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              validator: (v) {
                final sen = parseRmToSen(v);
                if (sen == null) return 'Enter your bid amount.';
                if (sen <= 0) return 'Amount must be more than RM 0.';
                return null;
              },
            ),
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
              onChanged: (v) =>
                  setState(() => _escrowAcknowledged = v ?? false),
              title: Text(
                'I understand FairBid uses milestone escrow: the client '
                'funds the job and payment is released as work is approved.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 8),
            PrimaryButton(
              label: 'Submit Bid',
              busy: controller.isBusy,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}
