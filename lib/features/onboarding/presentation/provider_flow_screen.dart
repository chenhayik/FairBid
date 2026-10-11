import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../auth/presentation/auth_controller.dart';
import '../domain/onboarding_data.dart';
import 'onboarding_controller.dart';
import 'onboarding_scaffold.dart';
import 'pending_review_screen.dart';
import 'steps/identity_step.dart';
import 'steps/payout_step.dart';
import 'steps/profile_step.dart';
import 'steps/provider_type_step.dart';
import 'steps/service_step.dart';

/// What:   The 6-stage provider onboarding flow.
/// Input:  [OnboardingController] (onboarding_controller.dart); verificationStatus from [AuthController].
/// Output: OnboardingScaffold around the current step, or PendingReviewScreen once submitted.
class ProviderFlowScreen extends StatefulWidget {
  const ProviderFlowScreen({super.key});

  @override
  State<ProviderFlowScreen> createState() => _ProviderFlowScreenState();
}

class _ProviderFlowScreenState extends State<ProviderFlowScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final uid = context.read<AuthController>().user?.uid;
      if (uid != null) context.read<OnboardingController>().loadFor(uid);
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final onboarding = context.watch<OnboardingController>();

    if (auth.user?.verificationStatus == 'pending') {
      return const PendingReviewScreen();
    }

    if (!onboarding.isLoaded) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final step = onboarding.data.step;
    final (sectionLabel, content) = switch (step) {
      2 => ('Provider Type', const ProviderTypeStep()),
      3 => ('Identity Verification', const IdentityStep()),
      4 => ('Profile Setup', const ProfileStep()),
      5 => ('Service Profile Setup', const ServiceStep()),
      _ => ('Payout Details', const PayoutStep()),
    };

    return OnboardingScaffold(
      step: step,
      totalStages: OnboardingData.lastStep,
      sectionLabel: sectionLabel,
      goBack: onboarding.goBack,
      content: content,
    );
  }
}
