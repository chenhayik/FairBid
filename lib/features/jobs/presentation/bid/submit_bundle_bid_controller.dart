import 'package:flutter/foundation.dart';

import '../../data/bundle_bid_repository.dart';

/// ViewModel for the Submit-a-Bundle-Bid sheet: manages the busy flag and
/// error message around the repository calls, mirroring
/// `SubmitBidController` for the per-job sheet.
class SubmitBundleBidController extends ChangeNotifier {
  SubmitBundleBidController(this._bundleBids);

  final BundleBidRepository _bundleBids;

  bool _busy = false;
  String? _errorMessage;

  bool get isBusy => _busy;
  String? get errorMessage => _errorMessage;

  /// Submits the bundle bid; returns true on success so the sheet can close.
  Future<bool> submit({
    required String bundleId,
    required Map<String, int> taskPrices,
    int? bundlePriceSen,
    bool allOrNothing = false,
    required String estimatedDuration,
    String message = '',
  }) async {
    _busy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _bundleBids.submit(
        bundleId: bundleId,
        taskPrices: taskPrices,
        bundlePriceSen: bundlePriceSen,
        allOrNothing: allOrNothing,
        estimatedDuration: estimatedDuration,
        message: message,
      );
      return true;
    } on BundleBidRejectedException catch (e) {
      _errorMessage = e.message;
      return false;
    } catch (_) {
      _errorMessage = 'Could not submit your bid. Please try again.';
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Withdraws the caller's bid on [bundleId]; returns true on success so the
  /// sheet can close.
  Future<bool> withdraw(String bundleId) async {
    _busy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _bundleBids.withdraw(bundleId);
      return true;
    } on BundleBidRejectedException catch (e) {
      _errorMessage = e.message;
      return false;
    } catch (_) {
      _errorMessage = 'Could not withdraw your bid. Please try again.';
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
