import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/app_widgets.dart';
import '../domain/mfa.dart';
import 'auth_controller.dart';

/// Asks for the 6-digit code from the user's authenticator app to finish a
/// sign-in or re-authentication that Firebase paused for a second factor.
///
/// [show] resolves true once the code is accepted. A wrong code is retried
/// against the same challenge; an expired one closes the sheet so the caller
/// can restart sign-in.
class MfaCodeSheet extends StatefulWidget {
  const MfaCodeSheet({super.key, required this.challenge});

  final MfaChallenge challenge;

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
    // Clear the controller's copy so the screen behind this sheet doesn't
    // also render it in its own error banner.
    auth.clearError();
    // An expired challenge can't be retried - close so the caller restarts.
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
