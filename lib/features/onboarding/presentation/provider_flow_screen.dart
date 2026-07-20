import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/form_widgets.dart';
import '../../auth/presentation/auth_controller.dart';
import '../domain/onboarding_data.dart';
import 'onboarding_controller.dart';
import 'pending_review_screen.dart';
import 'steps/identity_step.dart';
import 'steps/payout_step.dart';
import 'steps/profile_step.dart';
import 'steps/provider_type_step.dart';
import 'steps/service_step.dart';

/// Hosts the 6-stage provider onboarding flow: an app bar with back navigation,
/// the stage progress header, and the current stage's content. Once submitted,
/// shows the pending-review screen.
class ProviderFlowScreen extends StatefulWidget {
  const ProviderFlowScreen({super.key});

  @override
  State<ProviderFlowScreen> createState() => _ProviderFlowScreenState();
}

class _ProviderFlowScreenState extends State<ProviderFlowScreen> {
  @override
  void initState() {
    super.initState();
    // Load saved progress for the signed-in user after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final uid = context.read<AuthController>().user?.uid;
      if (uid != null) context.read<OnboardingController>().loadFor(uid);
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final onboarding = context.watch<OnboardingController>();

    // Submitted (this session or a previous one) → pending review screen.
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Onboarding'),
        leading: BackButton(
          onPressed: () {
            // Back one stage; from the first stage, back out to sign-in.
            final onboarding = context.read<OnboardingController>();
            if (!onboarding.goBack()) {
              context.read<AuthController>().signOut();
            }
          },
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  child: StageHeader(
                    stage: step,
                    totalStages: OnboardingData.totalStages,
                    sectionLabel: sectionLabel,
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                    child: content,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
