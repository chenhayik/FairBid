import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/form_widgets.dart';
import '../../auth/presentation/auth_controller.dart';
import '../domain/requestor_onboarding_data.dart';
import 'onboarding_exit.dart';
import 'requestor_onboarding_controller.dart';
import 'requestor_steps/account_type_step.dart';
import 'requestor_steps/details_step.dart';
import 'requestor_steps/verify_step.dart';

/// Hosts the requestor onboarding flow: an app bar with back navigation, the
/// stage progress header, and the current stage's content. The lighter,
/// 3-stage counterpart to the provider flow.
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Onboarding'),
        leading: BackButton(
          onPressed: () {
            final onboarding = context.read<RequestorOnboardingController>();
            // Back one stage; from the first stage, leave the flow entirely.
            if (!onboarding.goBack()) {
              exitOnboarding(context);
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
                    totalStages: RequestorOnboardingData.totalStages,
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
