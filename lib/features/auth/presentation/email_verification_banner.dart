import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_widgets.dart';
import 'auth_controller.dart';

/// What:   Dashboard banner nudging the user to verify their email.
/// Input:  [AuthController.user]; checks on app resume and on the refresh button.
/// Output: Banner with Resend (60s cooldown) and refresh; nothing once verified.
class EmailVerificationBanner extends StatefulWidget {
  const EmailVerificationBanner({super.key});

  @override
  State<EmailVerificationBanner> createState() =>
      _EmailVerificationBannerState();
}

class _EmailVerificationBannerState extends State<EmailVerificationBanner>
    with WidgetsBindingObserver {
  static const _resendCooldown = Duration(seconds: 60);

  Timer? _cooldownTimer;
  Duration _remaining = Duration.zero;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  /// What:   Re-checks whether the email is verified.
  /// Input:  AuthController.refreshEmailVerified().
  /// Output: Spinner while checking; success removes the banner through the controller update.
  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    await context.read<AuthController>().refreshEmailVerified();
    // A successful check removes this widget via notifyListeners.
    if (mounted) setState(() => _checking = false);
  }

  /// What:   Re-sends the verification email.
  /// Input:  AuthController.sendEmailVerification().
  /// Output: Snackbar with the result and a resend cooldown on success.
  Future<void> _resend() async {
    final auth = context.read<AuthController>();
    final sent = await auth.sendEmailVerification();
    if (!mounted) return;
    if (sent) _startCooldown();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(sent
          ? 'Verification email sent. Check your inbox and spam folder.'
          : auth.errorMessage ?? 'Could not send the email. Try again later.'),
    ));
  }

  /// What:   Counts down the resend button.
  /// Input:  [_resendCooldown].
  /// Output: Updates [_remaining] every second until zero.
  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _remaining = _resendCooldown);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _remaining -= const Duration(seconds: 1));
      if (_remaining <= Duration.zero) timer.cancel();
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthController>().user;
    if (user == null || user.emailVerified) return const SizedBox.shrink();

    final cooling = _remaining > Duration.zero;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: InfoBanner(
        icon: Icons.mark_email_unread_outlined,
        title: 'Verify your email',
        body: 'We sent a link to ${user.email ?? 'your inbox'}. '
            'Verifying protects your account and is required before you can '
            'turn on two-factor authentication.',
        color: context.fairbid.warningText,
        background: context.fairbid.warning.withValues(alpha: 0.12),
        leftAccent: true,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: "I've verified - refresh",
              onPressed: _checking ? null : _check,
              icon: _checking
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
            TextButton(
              onPressed: cooling ? null : _resend,
              child: Text(cooling ? '${_remaining.inSeconds}s' : 'Resend'),
            ),
          ],
        ),
      ),
    );
  }
}
