import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/form_widgets.dart';
import '../../../core/widgets/icon_choice_card.dart';
import '../domain/user_role.dart';
import 'auth_controller.dart';
import 'mfa_code_sheet.dart';
import 'validators.dart';

/// What:   Sign-up screen: Hire / Work role cards, form, terms checkbox and Google sign-up.
/// Input:  [AuthController] (auth_controller.dart).
/// Output: Registers the account; the router redirect then continues the flow.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  UserRole _role = UserRole.provider;
  bool _agreedToTerms = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_agreedToTerms) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please agree to the Terms of Service first.')));
      return;
    }
    await context.read<AuthController>().register(
          email: _email.text,
          password: _password.text,
          displayName: _name.text,
          role: _role,
        );
  }

  Future<void> _google() async {
    // The picked role applies only if this Google account is new.
    final auth = context.read<AuthController>();
    await auth.signInWithGoogle(roleIfNew: _role);
    if (!mounted) return;
    final challenge = auth.takePendingChallenge();
    if (challenge != null) await MfaCodeSheet.show(context, challenge: challenge);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Account'),
        leading: BackButton(onPressed: () => context.go('/login')),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Join FairBid',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium),
                  const SizedBox(height: 8),
                  Text(
                    'Connect with professionals or find your next gig.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  if (auth.errorMessage != null)
                    ErrorBanner(auth.errorMessage!),
                  Text('I WANT TO...', style: theme.textTheme.labelMedium),
                  const SizedBox(height: 8),
                  IconChoiceCard(
                    icon: Icons.person_search_outlined,
                    title: 'Hire',
                    subtitle: 'Find talent for projects',
                    selected: _role == UserRole.requestor,
                    onTap: () => setState(() => _role = UserRole.requestor),
                  ),
                  const SizedBox(height: 12),
                  IconChoiceCard(
                    icon: Icons.work_outline,
                    title: 'Work',
                    subtitle: 'Offer my services',
                    selected: _role == UserRole.provider,
                    onTap: () => setState(() => _role = UserRole.provider),
                  ),
                  const SizedBox(height: 24),
                  Form(
                    key: _formKey,
                    child: Column(
                      children: [
                        AppTextField(
                          controller: _name,
                          label: 'FULL NAME',
                          hint: 'Jane Doe',
                          prefixIcon: Icons.person_outline,
                          textInputAction: TextInputAction.next,
                          validator: (v) => Validators.required(v, 'Name'),
                        ),
                        AppTextField(
                          controller: _email,
                          label: 'EMAIL ADDRESS',
                          hint: 'jane@example.com',
                          prefixIcon: Icons.mail_outline,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          validator: Validators.email,
                        ),
                        AppTextField(
                          controller: _password,
                          label: 'PASSWORD',
                          prefixIcon: Icons.lock_outline,
                          obscure: true,
                          textInputAction: TextInputAction.next,
                          validator: Validators.password,
                          helperText: 'Must be at least 8 characters.',
                        ),
                        AppTextField(
                          controller: _confirm,
                          label: 'CONFIRM PASSWORD',
                          prefixIcon: Icons.lock_reset_outlined,
                          obscure: true,
                          textInputAction: TextInputAction.done,
                          validator: (v) =>
                              Validators.confirmPassword(v, _password.text),
                        ),
                      ],
                    ),
                  ),
                  CheckboxListTile(
                    value: _agreedToTerms,
                    onChanged: (v) => setState(() => _agreedToTerms = v!),
                    activeColor: context.fairbid.verified,
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'I agree to the Terms of Service and Privacy Policy.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  const SizedBox(height: 16),
                  PrimaryButton(
                    label: 'Sign Up',
                    busy: auth.isBusy,
                    onPressed: _submit,
                  ),
                  const OrDivider(),
                  GoogleButton(
                    enabled: !auth.isBusy,
                    onPressed: _google,
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('Already have an account?',
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                      TextButton(
                        onPressed: () => context.go('/login'),
                        child: const Text('Log In'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '© 2026 FairBid. All rights reserved.',
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
