import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../auth/presentation/auth_controller.dart';

/// Handles the onboarding back arrow once there is no earlier stage to step
/// back to.
///
/// Onboarding is reachable two ways, and the right "back" differs between
/// them. The router sends a brand-new account here with nothing beneath it on
/// the stack, so leaving really does mean ending the session. But a provider
/// whose verification was rejected can also push this flow from a job or from
/// their dashboard, and there the user simply wants the screen they came from.
/// Popping when we can covers the second case; confirming first covers the
/// first, so a single stray tap on a universally-understood affordance can no
/// longer sign someone out.
Future<void> exitOnboarding(BuildContext context) async {
  if (context.canPop()) {
    context.pop();
    return;
  }

  final leave = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Leave onboarding?'),
      content: const Text(
        "You'll be signed out. Anything you've already saved is kept, so you "
        'can carry on from here next time you sign in.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Stay'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Sign out'),
        ),
      ],
    ),
  );

  if (leave == true && context.mounted) {
    context.read<AuthController>().signOut();
  }
}
