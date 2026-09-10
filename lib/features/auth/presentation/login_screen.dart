import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/form_widgets.dart';
import '../data/auth_config.dart';
import '../domain/user_role.dart';
import 'auth_controller.dart';
import 'mfa_code_sheet.dart';
import 'validators.dart';

/// "Welcome to FairBid" - email/password + Google sign-in, with the
/// Log In / Sign Up tab strip from the design mock.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final auth = context.read<AuthController>();
    // Navigation happens automatically via the router's auth redirect.
    await auth.signInWithEmail(_email.text, _password.text);
    if (!mounted) return;
    await _resolveMfaIfNeeded(auth);
  }

  Future<void> _google() async {
    final auth = context.read<AuthController>();
    // Existing Google users keep their stored role; roleIfNew only applies to
    // a first-time Google account.
    await auth.signInWithGoogle(roleIfNew: UserRole.requestor);
    if (!mounted) return;
    await _resolveMfaIfNeeded(auth);
  }

  /// Prompts for the second factor when Firebase asked for one. Nothing to do
  /// on success - the router redirect handles it, same as a normal sign-in.
  Future<void> _resolveMfaIfNeeded(AuthController auth) async {
    final challenge = auth.takePendingChallenge();
    if (challenge == null) return;
    await MfaCodeSheet.show(context, challenge: challenge);
  }

  Future<void> _forgotPassword() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter your email first')));
      return;
    }
    final auth = context.read<AuthController>();
    final ok = await auth.sendPasswordReset(email);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? 'Password reset email sent to $email'
            : auth.errorMessage ??
                'Could not send the reset email. Please try again.')));
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Welcome to FairBid',
                      style: theme.textTheme.headlineMedium),
                  const SizedBox(height: 8),
                  Text('Please log in to continue.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 24),
                  _AuthTabs(
                    loginSelected: true,
                    onSignUp: () => context.go('/register'),
                  ),
                  const SizedBox(height: 24),
                  if (auth.errorMessage != null)
                    ErrorBanner(auth.errorMessage!),
                  Form(
                    key: _formKey,
                    child: Column(
                      children: [
                        AppTextField(
                          controller: _email,
                          label: 'Email',
                          hint: 'you@example.com',
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          validator: Validators.email,
                        ),
                        AppTextField(
                          controller: _password,
                          label: 'Password',
                          obscure: true,
                          textInputAction: TextInputAction.done,
                          validator: Validators.password,
                          onSubmitted: (_) => _submit(),
                          labelTrailing: GestureDetector(
                            onTap: auth.isBusy ? null : _forgotPassword,
                            child: Text(
                              'Forgot?',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                  color: context.fairbid.verified,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  PrimaryButton(
                    label: 'Log In',
                    busy: auth.isBusy,
                    onPressed: _submit,
                  ),
                  const OrDivider(),
                  GoogleButton(
                    enabled: !auth.isBusy && isGoogleSignInConfigured,
                    onPressed: _google,
                  ),
                  const SizedBox(height: 40),
                  Text(
                    '© 2026 FairBid. All rights reserved. '
                    'Professional Services in RM.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Log In / Sign Up tab strip at the top of the auth screens.
class _AuthTabs extends StatelessWidget {
  const _AuthTabs({required this.loginSelected, required this.onSignUp});

  final bool loginSelected;
  final VoidCallback onSignUp;

  @override
  Widget build(BuildContext context) {
    Widget tab(String label, bool selected, VoidCallback? onTap) {
      final brand = context.fairbid.verified;
      return Expanded(
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: selected ? brand : context.fairbid.borderSubtle,
                  width: selected ? 2 : 1,
                ),
              ),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: selected
                        ? brand
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        tab('Log In', loginSelected, null),
        tab('Sign Up', !loginSelected, onSignUp),
      ],
    );
  }
}
