import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'auth_controller.dart';

/// What:   Full-app lock screen for a suspended account.
/// Input:  [AuthController.user] suspensionReason; the router redirects every route here.
/// Output: Message and Sign Out; reinstatement clears it live via the profile stream.
class SuspendedScreen extends StatelessWidget {
  const SuspendedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reason = context.watch<AuthController>().user?.suspensionReason;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.block_rounded,
                  size: 72,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: 24),
                Text(
                  'Account suspended',
                  style: theme.textTheme.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  reason == null || reason.isEmpty
                      ? 'An administrator has suspended your account. Please '
                            'contact support if you think this is a mistake.'
                      : 'An administrator has suspended your account:\n\n'
                            '"$reason"\n\nContact support if you think this is '
                            'a mistake.',
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                OutlinedButton(
                  onPressed: () => context.read<AuthController>().signOut(),
                  child: const Text('Sign Out'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
