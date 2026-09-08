import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/app_user.dart';
import 'auth_controller.dart';

/// Asks the user to prove who they are again, immediately before a sensitive
/// action (withdrawing money, deleting the account).
///
/// Password accounts type their password; Google accounts are sent back
/// through the Google sheet, so they see no field - just a confirm button.
/// [show] resolves true only once Firebase accepted the credentials.
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

  /// Shows the dialog and returns whether identity was confirmed. Dismissing
  /// it counts as a no.
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
