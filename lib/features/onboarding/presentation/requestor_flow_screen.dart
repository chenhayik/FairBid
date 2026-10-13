import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../auth/presentation/auth_controller.dart';
import '../domain/requestor_onboarding_data.dart';
import 'onboarding_scaffold.dart';
import 'requestor_onboarding_controller.dart';
import 'requestor_steps/account_type_step.dart';
import 'requestor_steps/details_step.dart';
import 'requestor_steps/verify_step.dart';

/// What:   The 3-stage requestor onboarding flow.
/// Input:  [RequestorOnboardingController] (requestor_onboarding_controller.dart).
/// Output: OnboardingScaffold around the current step.
class RequestorFlowScreen extends StatefulWidget {
  const RequestorFlowScreen({super.key});

  @override
  State<RequestorFlowScreen> createState() => _RequestorFlowScreenState();
}

class _RequestorFlowScreenState extends State<RequestorFlowScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final user = context.read<AuthController>().user;
      if (user != null) {
        context
            .read<RequestorOnboardingController>()
            .loadFor(user.uid, fallbackName: user.displayName);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final onboarding = context.watch<RequestorOnboardingController>();

    if (!onboarding.isLoaded) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final step = onboarding.data.step;
    final (sectionLabel, content) = switch (step) {
      1 => ('Account Type', const AccountTypeStep()),
      2 => ('Your Details', const DetailsStep()),
      _ => ('Get Verified', const VerifyStep()),
    };

    return OnboardingScaffold(
      step: step,
      totalStages: RequestorOnboardingData.lastStep,
      sectionLabel: sectionLabel,
      goBack: onboarding.goBack,
      content: content,
    );
  }
}
