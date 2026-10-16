import 'package:flutter/foundation.dart';

import '../../data/bundle_bid_repository.dart';

/// What:   Busy flag and error message for the bundle-bid sheet.
/// Input:  BundleBidRepository (bundle_bid_repository.dart).
/// Output: submit()/withdraw() return true on success so the sheet can close.
class SubmitBundleBidController extends ChangeNotifier {
  SubmitBundleBidController(this._bundleBids);

  final BundleBidRepository _bundleBids;

  bool _busy = false;
  String? _errorMessage;

  bool get isBusy => _busy;
  String? get errorMessage => _errorMessage;

  /// What:   Submits the package bid.
  /// Input:  Bundle id, per-task prices (sen), optional bundle price, duration and message from the sheet.
  /// Output: True on success; false with [errorMessage] set.
  Future<bool> submit({
    required String bundleId,
    required Map<String, int> taskPrices,
    int? bundlePriceSen,
    required String estimatedDuration,
    String message = '',
  }) => _run(
    () => _bundleBids.submit(
      bundleId: bundleId,
      taskPrices: taskPrices,
      bundlePriceSen: bundlePriceSen,
      estimatedDuration: estimatedDuration,
      message: message,
    ),
    'Could not submit your bid. Please try again.',
  );

  /// What:   Withdraws the caller's bid on [bundleId].
  /// Output: True on success; false with [errorMessage] set.
  Future<bool> withdraw(String bundleId) => _run(
    () => _bundleBids.withdraw(bundleId),
    'Could not withdraw your bid. Please try again.',
  );

  /// What:   Shared busy/error wrapper for the repository calls.
  /// Output: True on success; on failure sets the server message (BundleBidRejectedException) or [failure].
  Future<bool> _run(Future<void> Function() call, String failure) async {
    _busy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await call();
      return true;
    } on BundleBidRejectedException catch (e) {
      _errorMessage = e.message;
      return false;
    } catch (_) {
      _errorMessage = failure;
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
