import 'package:flutter/foundation.dart';

import '../../data/bid_repository.dart';
import '../../domain/bid.dart';

/// What:   Busy flag and error message for the single-job bid sheet.
/// Input:  BidRepository.submitBid() (bid_repository.dart).
/// Output: submit() returns true on success so the sheet can close.
class SubmitBidController extends ChangeNotifier {
  SubmitBidController(this._bids);

  final BidRepository _bids;

  bool _busy = false;
  String? _errorMessage;

  bool get isBusy => _busy;
  String? get errorMessage => _errorMessage;

  /// What:   Submits the bid and tracks busy/error state.
  /// Input:  [bid] built by SubmitBidSheet.
  /// Output: True on success; false with [errorMessage] set (stale profile or generic failure).
  Future<bool> submit(Bid bid) async {
    _busy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _bids.submitBid(bid);
      return true;
    } on BidRejectedException {
      _errorMessage = 'Your profile changed since you opened this form. '
          'Close it, reopen the bid, and submit again.';
      return false;
    } catch (_) {
      _errorMessage = 'Could not submit the bid. Please try again.';
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
