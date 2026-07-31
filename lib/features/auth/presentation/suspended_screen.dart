import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'auth_controller.dart';

/// Shown to a user whose account an admin has suspended. The router redirects
/// every other route here, so it stands in for the whole app; it offers only
/// sign-out. An admin reinstates the account, after which the live profile
/// stream clears [AppUser.suspended] and the router lets the user back in
/// automatically — no re-login needed.
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
