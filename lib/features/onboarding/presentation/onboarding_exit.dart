import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/app_widgets.dart';
import '../../auth/presentation/auth_controller.dart';

/// What:   Back-arrow handler for the first onboarding stage.
/// Input:  [context]; whether the flow was pushed (rejected provider) or is the stack root (new account).
/// Output: Pops when pushed; otherwise confirms, then signs out.
Future<void> exitOnboarding(BuildContext context) async {
  if (context.canPop()) {
    context.pop();
    return;
  }

  final leave = await showConfirmDialog(
    context,
    title: 'Leave onboarding?',
    body: "You'll be signed out. Anything you've already saved is kept, so you "
        'can carry on from here next time you sign in.',
    actionLabel: 'Sign out',
    cancelLabel: 'Stay',
  );

  if (leave && context.mounted) {
    context.read<AuthController>().signOut();
  }
}
