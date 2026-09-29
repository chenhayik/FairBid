import 'package:flutter/material.dart';

import '../../../../core/util/money.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../domain/bundle_award.dart';
import '../../domain/bundle_bid.dart';
import '../../domain/job.dart';
import 'bundle_buttons.dart';
import 'bundle_option_card.dart';

/// The client's own pick matrix: one dropdown per task, then a button to
/// price the pick through the same shape the automatic options use. Hidden
/// entirely when nobody has bid yet - there is nothing to pick from.
class BundleManualAwardSection extends StatelessWidget {
  const BundleManualAwardSection({
    super.key,
    required this.tasks,
    required this.bids,
    required this.picks,
    required this.onPick,
    required this.onCheckPrice,
    required this.busy,
    required this.option,
    required this.problems,
    required this.awarding,
    required this.onAward,
  });

  final List<Job> tasks;
  final List<BundleBid> bids;
  final Map<String, String?> picks;
  final void Function(String taskId, String? providerId) onPick;
  final VoidCallback onCheckPrice;
  final bool busy;
  final BundleAwardOption? option;
  final List<String> problems;
  final bool awarding;
  final void Function(BundleAwardOption) onAward;

  /// A dropdown item's contents: name ellipsised, price fixed on the right -
  /// used both for the closed field ([selectedItemBuilder]) and the open
  /// menu, so a long provider name never clips the price.
  Widget _pickRow(String name, int amountSen) => Row(
    children: [
      Expanded(child: Text(name, overflow: TextOverflow.ellipsis)),
      const SizedBox(width: 8),
      Text(formatRm(amountSen)),
    ],
  );

  @override
  Widget build(BuildContext context) {
    // Nothing to pick from yet - hide the whole section rather than show an
    // empty matrix of "Don't award" dropdowns.
    if (bids.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final hasPick = picks.values.any((v) => v != null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Pick providers yourself', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        for (final task in tasks)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(task.title, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 4),
                DropdownButtonFormField<String?>(
                  isExpanded: true,
                  initialValue: picks[task.id],
                  decoration: const InputDecoration(),
                  selectedItemBuilder: (context) => [
                    const Text("Don't award", overflow: TextOverflow.ellipsis),
                    for (final bid in bids.where((b) => b.coversTask(task.id)))
                      _pickRow(bid.providerName, bid.priceFor(task.id)!),
                  ],
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text("Don't award"),
                    ),
                    for (final bid in bids.where((b) => b.coversTask(task.id)))
                      DropdownMenuItem(
                        value: bid.providerId,
                        child: _pickRow(
                          bid.providerName,
                          bid.priceFor(task.id)!,
                        ),
                      ),
                  ],
                  onChanged: (value) => onPick(task.id, value),
                ),
              ],
            ),
          ),
        OutlinedBusyButton(
          label: 'Check price',
          busy: busy,
          onPressed: hasPick ? onCheckPrice : null,
        ),
        if (problems.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: ErrorBanner(problems.join('\n')),
          ),
        if (option != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: BundleOptionCard(
              merged: MergedBundleOption(option!, [option!.label]),
              tasks: tasks,
              primary: false,
              busy: awarding,
              enabled: true,
              onAward: () => onAward(option!),
            ),
          ),
      ],
    );
  }
}
