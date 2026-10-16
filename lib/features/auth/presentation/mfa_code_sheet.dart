import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/app_widgets.dart';
import '../domain/mfa.dart';
import 'auth_controller.dart';

/// What:   Bottom sheet asking for the authenticator app's 6-digit code.
/// Input:  [MfaChallenge] from a paused sign-in or re-auth; [AuthController.submitMfaCode].
/// Output: [show] resolves true once accepted; a wrong code retries, an expired one closes it.
class MfaCodeSheet extends StatefulWidget {
  const MfaCodeSheet({super.key, required this.challenge});

  final MfaChallenge challenge;

  /// What:   Opens the code sheet for a second-factor challenge.
  /// Input:  [challenge] from AuthController.takePendingChallenge().
  /// Output: True once the code is accepted, false if closed or the challenge expired.
  static Future<bool> show(
    BuildContext context, {
    required MfaChallenge challenge,
  }) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: MfaCodeSheet(challenge: challenge),
      ),
    );
    return ok ?? false;
  }

  @override
  State<MfaCodeSheet> createState() => _MfaCodeSheetState();
}

class _MfaCodeSheetState extends State<MfaCodeSheet> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  /// What:   Submits the 6-digit code.
  /// Input:  The code field; AuthController.submitMfaCode().
  /// Output: Pops true on success; shows the error on a wrong code; pops false when the challenge expired.
  Future<void> _submit() async {
    if (_code.text.length != 6) {
      setState(() => _error = 'Enter the 6-digit code.');
      return;
    }
    final auth = context.read<AuthController>();
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await auth.submitMfaCode(widget.challenge, _code.text);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    final message = auth.errorMessage ?? 'Could not verify that code.';
    // Clear the controller's copy so the screen behind doesn't show it too.
    auth.clearError();
    // An expired challenge can't be retried; close so the caller restarts.
    if (message.contains('sign in again')) {
      Navigator.of(context).pop(false);
      return;
    }
    setState(() {
      _busy = false;
      _error = message;
      _code.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Two-factor authentication',
                style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'Enter the 6-digit code from your authenticator app.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _code,
              autofocus: true,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineMedium?.copyWith(letterSpacing: 8),
              decoration: InputDecoration(
                hintText: '000000',
                errorText: _error,
                counterText: '',
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 24),
            PrimaryButton(label: 'Verify', busy: _busy, onPressed: _submit),
            const SizedBox(height: 8),
            TextButton(
              onPressed:
                  _busy ? null : () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}
