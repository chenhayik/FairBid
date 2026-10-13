import 'package:flutter/material.dart';

import '../../../core/widgets/form_widgets.dart';
import 'onboarding_exit.dart';

/// What:   Shared page frame for the provider and requestor onboarding flows.
/// Input:  Current [step] of [totalStages] (the last step number), its [sectionLabel] and [content]; [goBack] from the controller.
/// Output: App bar with back (steps back, or leaves via exitOnboarding), StageHeader and scrolling content.
class OnboardingScaffold extends StatelessWidget {
  const OnboardingScaffold({
    super.key,
    required this.step,
    required this.totalStages,
    required this.sectionLabel,
    required this.goBack,
    required this.content,
  });

  final int step;
  final int totalStages;
  final String sectionLabel;
  final bool Function() goBack;
  final Widget content;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Onboarding'),
        leading: BackButton(
          onPressed: () {
            if (!goBack()) exitOnboarding(context);
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
                    totalStages: totalStages,
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
