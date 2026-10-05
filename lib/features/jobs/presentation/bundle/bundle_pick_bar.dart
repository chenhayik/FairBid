import 'package:flutter/material.dart';

import '../../../../core/util/money.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../domain/bundle_award.dart';
import 'bundle_warning_banner.dart';

/// Sticky bottom bar for the client's own picks: the server-priced total,
/// any problems, and the Award button.
class BundlePickBar extends StatelessWidget {
  const BundlePickBar({
    super.key,
    required this.option,
    required this.problems,
    required this.pricing,
    required this.stale,
    required this.awarding,
    required this.onRefresh,
    required this.onAward,
  });

  /// The priced pick, or null while pricing or when the server refused it.
  final BundleAwardOption? option;
  final List<String> problems;
  final bool pricing;

  /// The bids changed since [option] was priced.
  final bool stale;
  final bool awarding;
  final VoidCallback onRefresh;
  final VoidCallback onAward;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canAward =
        option != null && problems.isEmpty && !pricing && !stale && !awarding;
    return Material(
      elevation: 8,
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (problems.isNotEmpty) ErrorBanner(problems.join('\n')),
            if (stale)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: WarningBanner(
                  'The bids have changed. Check your pick again.',
                  trailing: TextButton(
                    onPressed: onRefresh,
                    child: const Text('Refresh'),
                  ),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    option == null
                        ? 'Your pick'
                        : 'Your pick: ${formatRm(option!.totalSen)}',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (pricing)
                  const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            PrimaryButton(
              label: 'Award your pick',
              busy: awarding,
              onPressed: canAward ? onAward : null,
            ),
          ],
        ),
      ),
    );
  }
}
