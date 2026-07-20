import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../auth/domain/user_role.dart';
import '../../auth/presentation/auth_controller.dart';
import 'provider_flow_screen.dart';
import 'requestor_flow_screen.dart';

/// The single `/onboarding` route. Dispatches to the right onboarding flow
/// based on the signed-in user's role: the 6-stage provider flow, or the
/// lighter 3-stage requestor flow.
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
