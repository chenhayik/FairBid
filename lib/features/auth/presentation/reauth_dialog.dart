import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/app_user.dart';
import 'auth_controller.dart';
import 'mfa_code_sheet.dart';

/// What:   Dialog re-proving identity before a sensitive action (withdraw, delete account).
/// Input:  [user] (password field only for password accounts), [message], [actionLabel].
/// Output: [show] resolves true only once Firebase accepted the credentials; dismissing is false.
/// Notes:  Google accounts see just a confirm button and go through the Google sheet.
class ReauthDialog extends StatefulWidget {
  const ReauthDialog({
    super.key,
    required this.user,
    required this.message,
    this.actionLabel = 'Confirm',
  });

  final AppUser user;
  final String message;
  final String actionLabel;

  static Future<bool> show(
    BuildContext context, {
    required AppUser user,
    required String message,
    String actionLabel = 'Confirm',
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => ReauthDialog(
        user: user,
        message: message,
        actionLabel: actionLabel,
      ),
    );
    return confirmed ?? false;
  }

  @override
  State<ReauthDialog> createState() => _ReauthDialogState();
}

class _ReauthDialogState extends State<ReauthDialog> {
  final _password = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final auth = context.read<AuthController>();
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await auth.reauthenticate(
      password: _password.text.isEmpty ? null : _password.text,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }

    // An enrolled user must also pass the second factor.
    final challenge = auth.takePendingChallenge();
    if (challenge != null) {
      // Stop the spinner while the code sheet is on top.
      setState(() => _busy = false);
      final verified = await MfaCodeSheet.show(context, challenge: challenge);
      if (!mounted) return;
      if (verified) {
        Navigator.of(context).pop(true);
        return;
      }
    }

    setState(() {
      _busy = false;
      _error = auth.errorMessage ?? 'Could not confirm your identity.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Confirm it's you"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message),
          if (widget.user.isPasswordAccount) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _password,
              obscureText: _obscure,
              autofocus: true,
              enabled: !_busy,
              onSubmitted: (_) => _confirm(),
              decoration: InputDecoration(
                labelText: 'Your password',
                errorText: _error,
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                  icon: Icon(
                      _obscure ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
          ] else if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _confirm,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(widget.actionLabel),
        ),
      ],
    );
  }
}
