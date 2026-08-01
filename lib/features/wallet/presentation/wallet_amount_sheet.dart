import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../../core/util/money.dart';
import '../../../core/util/payment_log.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/form_widgets.dart';

/// Bottom sheet that asks for an RM amount and runs a wallet action (top-up
/// or withdraw). [show] resolves `true` once the action succeeded.
class WalletAmountSheet extends StatefulWidget {
  const WalletAmountSheet({
    super.key,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onSubmit,
    this.maxSen,
  });

  final String title;
  final String subtitle;
  final String actionLabel;

  /// The wallet call to run with the entered amount.
  final Future<void> Function(int amountSen) onSubmit;

  /// Optional upper bound, e.g. the available balance for withdrawals.
  final int? maxSen;

  static Future<bool?> show(
    BuildContext context, {
    required String title,
    required String subtitle,
    required String actionLabel,
    required Future<void> Function(int amountSen) onSubmit,
    int? maxSen,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => WalletAmountSheet(
        title: title,
        subtitle: subtitle,
        actionLabel: actionLabel,
        onSubmit: onSubmit,
        maxSen: maxSen,
      ),
    );
  }

  @override
  State<WalletAmountSheet> createState() => _WalletAmountSheetState();
}

class _WalletAmountSheetState extends State<WalletAmountSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  String? _validate(String? value) {
    final sen = parseRmToSen(value);
    if (sen == null) return 'Enter an amount.';
    if (sen <= 0) return 'Amount must be more than RM 0.';
    if (widget.maxSen != null && sen > widget.maxSen!) {
      return 'You can use at most ${formatRm(widget.maxSen!)}.';
    }
    return null;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final amountSen = parseRmToSen(_amount.text)!;
    try {
      await widget.onSubmit(amountSen);
      if (mounted) Navigator.of(context).pop(true);
    } on FirebaseFunctionsException catch (e, st) {
      logPayment('wallet_amount_sheet.submit.error',
          data: {'amountSen': amountSen, 'code': e.code},
          error: e,
          stackTrace: st);
      // The wallet functions raise user-readable messages — but fall back
      // rather than leaving the sheet with no explanation when one isn't set.
      if (mounted) {
        setState(() =>
            _error = e.message ?? 'Something went wrong. Please try again.');
      }
    } catch (e, st) {
      logPayment('wallet_amount_sheet.submit.error',
          data: {'amountSen': amountSen}, error: e, stackTrace: st);
      if (mounted) setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      // Keep the form above the keyboard.
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.title, style: theme.textTheme.headlineMedium),
              const SizedBox(height: 4),
              Text(
                widget.subtitle,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              if (_error != null) ErrorBanner(_error!),
              AppTextField(
                controller: _amount,
                label: 'Amount (RM)',
                hint: '0.00',
                prefixText: 'RM ',
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                validator: _validate,
              ),
              PrimaryButton(
                label: widget.actionLabel,
                busy: _busy,
                onPressed: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
