import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/form_widgets.dart';
import '../../../auth/presentation/auth_controller.dart';
import '../../../auth/presentation/validators.dart';
import '../onboarding_controller.dart';

/// Stage 6 — "Secure Payout Information": bank details + final submission.
class PayoutStep extends StatefulWidget {
  const PayoutStep({super.key});

  @override
  State<PayoutStep> createState() => _PayoutStepState();
}

class _PayoutStepState extends State<PayoutStep> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _bankName;
  late final TextEditingController _accountHolder;
  late final TextEditingController _accountNumber;
  late final TextEditingController _branchCode;

  @override
  void initState() {
    super.initState();
    final data = context.read<OnboardingController>().data;
    _bankName = TextEditingController(text: data.bankName);
    _accountHolder = TextEditingController(text: data.accountHolder);
    _accountNumber = TextEditingController(text: data.accountNumber);
    _branchCode = TextEditingController(text: data.branchCode);
  }

  @override
  void dispose() {
    _bankName.dispose();
    _accountHolder.dispose();
    _accountNumber.dispose();
    _branchCode.dispose();
    super.dispose();
  }

  void _copyIntoData() {
    context.read<OnboardingController>().data
      ..bankName = _bankName.text.trim()
      ..accountHolder = _accountHolder.text.trim()
      ..accountNumber = _accountNumber.text.trim()
      ..branchCode = _branchCode.text.trim();
  }

  Future<void> _saveForLater() async {
    _copyIntoData();
    final saved = await context.read<OnboardingController>().saveDraft();
    if (saved && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Progress saved.')));
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    _copyIntoData();
    final onboarding = context.read<OnboardingController>();
    final auth = context.read<AuthController>();
    final submitted = await onboarding.submitForReview();
    // Refresh the profile so verificationStatus=pending flows into the UI
    // and the flow switches to the pending-review screen.
    if (submitted) await auth.refreshUser();
  }

  @override
  Widget build(BuildContext context) {
    final onboarding = context.watch<OnboardingController>();
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Secure Payout Information', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'Please provide your bank details. These are required for escrow '
          'payouts (in RM) upon successful job completion.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        const InfoBanner(
          icon: Icons.lock_outline,
          leftAccent: true,
          title: 'Bank-Level Security',
          body: 'Your sensitive financial details are encrypted and stored '
              'masked. We never share your full account number with clients.',
        ),
        const SizedBox(height: 24),
        if (onboarding.errorMessage != null)
          ErrorBanner(onboarding.errorMessage!),
        Form(
          key: _formKey,
          child: Column(
            children: [
              AppTextField(
                controller: _bankName,
                label: 'Bank Name',
                hint: 'e.g. Maybank',
                prefixIcon: Icons.account_balance_outlined,
                validator: (v) => Validators.required(v, 'Bank name'),
              ),
              AppTextField(
                controller: _accountHolder,
                label: 'Account Holder Name',
                hint: 'Exact name on account',
                prefixIcon: Icons.person_outline,
                validator: (v) =>
                    Validators.required(v, 'Account holder name'),
              ),
              AppTextField(
                controller: _accountNumber,
                label: 'Account Number',
                hint: 'Enter account number',
                prefixIcon: Icons.numbers_outlined,
                obscure: true,
                keyboardType: TextInputType.number,
                helperText:
                    'Double-check for accuracy to avoid payout delays in RM.',
                validator: (v) => Validators.required(v, 'Account number'),
              ),
              AppTextField(
                controller: _branchCode,
                label: 'Branch Code / SWIFT',
                hint: 'Enter code',
                prefixIcon: Icons.qr_code_2_outlined,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SecondaryButton(label: 'Save for Later', onPressed: _saveForLater),
        const SizedBox(height: 12),
        PrimaryButton(
          label: 'Submit for Review',
          trailingIcon: Icons.verified_outlined,
          busy: onboarding.isBusy,
          onPressed: _submit,
        ),
      ],
    );
  }
}
