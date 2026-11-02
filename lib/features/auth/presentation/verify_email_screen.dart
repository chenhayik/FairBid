import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/app_widgets.dart';
import 'auth_controller.dart';

/// What:   Full-app lock screen until the user verifies their email.
/// Input:  [AuthController.user]; the router redirects every route here while unverified.
/// Output: "I've verified" check, Resend (60s cooldown) and Sign Out; the router moves on once verified.
/// How:    Re-checks on app resume (the user leaves to open the link) and on the button.
class VerifyEmailScreen extends StatefulWidget {
  const VerifyEmailScreen({super.key});

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen>
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
    if (state == AppLifecycleState.resumed) _check(quiet: true);
  }

  /// What:   Re-checks whether the email is verified.
  /// Input:  AuthController.refreshEmailVerified().
  /// Output: Success lets the router leave this screen; otherwise a snackbar unless [quiet].
  Future<void> _check({bool quiet = false}) async {
    if (_checking) return;
    setState(() => _checking = true);
    final verified =
        await context.read<AuthController>().refreshEmailVerified();
    if (!mounted) return;
    setState(() => _checking = false);
    if (!verified && !quiet) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("We couldn't see the confirmation yet. Open the link, "
            'then try again.'),
      ));
    }
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
    final theme = Theme.of(context);
    final email = context.watch<AuthController>().user?.email;
    final cooling = _remaining > Duration.zero;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.mark_email_unread_outlined,
                    size: 72, color: theme.colorScheme.primary),
                const SizedBox(height: 24),
                Text('Verify your email',
                    style: theme.textTheme.headlineMedium,
                    textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Text(
                  'We sent a link to ${email ?? 'your inbox'}. Tap it, then '
                  'come back here. Check your spam folder if you cannot see it.',
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                PrimaryButton(
                  label: "I've verified",
                  busy: _checking,
                  onPressed: _check,
                ),
                const SizedBox(height: 12),
                SecondaryButton(
                  label: cooling
                      ? 'Resend in ${_remaining.inSeconds}s'
                      : 'Resend email',
                  onPressed: cooling ? null : _resend,
                ),
                TextButton(
                  onPressed: () => context.read<AuthController>().signOut(),
                  child: const Text('Wrong email? Sign out'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
