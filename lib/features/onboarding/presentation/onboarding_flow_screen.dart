import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../auth/domain/user_role.dart';
import '../../auth/presentation/auth_controller.dart';
import 'provider_flow_screen.dart';
import 'requestor_flow_screen.dart';

/// What:   The `/onboarding` route.
/// Input:  Signed-in user's role from [AuthController].
/// Output: ProviderFlowScreen for providers, else RequestorFlowScreen.
class OnboardingFlowScreen extends StatelessWidget {
  const OnboardingFlowScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final role = context.watch<AuthController>().user?.role;
    return role == UserRole.provider
        ? const ProviderFlowScreen()
        : const RequestorFlowScreen();
  }
}
