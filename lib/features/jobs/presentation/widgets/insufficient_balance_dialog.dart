import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/util/money.dart';
import '../../data/bid_repository.dart';

/// What:   "Not enough balance" dialog for a refused accept or award.
/// Input:  [e] from BidRepository.acceptBid() or BundleRepository.award().
/// Output: Dialog with the shortfall and a Top up shortcut to `/profile/earnings`.
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
