import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/util/money.dart';
import '../../data/bid_repository.dart';

/// Shared "Not enough balance" dialog shown when an accept/award is refused
/// with [InsufficientBalanceException] - used by the job accept-bid flow and
/// the bundle award flow so both report a shortfall the same way and offer
/// the same "Top up" shortcut.
Future<void> showInsufficientBalanceDialog(
  BuildContext context,
  InsufficientBalanceException e,
) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Not enough balance'),
      content: Text(
        'You need ${formatRm(e.shortfallSen)} more available '
        'to hire for this (available: ${formatRm(e.availableSen)}, '
        'required: ${formatRm(e.requiredSen)}).',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop();
            context.push('/profile/earnings');
          },
          child: const Text('Top up'),
        ),
      ],
    ),
  );
}
