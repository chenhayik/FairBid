import 'package:flutter/foundation.dart';

import '../../data/bid_repository.dart';
import '../../domain/bid.dart';

/// ViewModel for the Submit-a-Bid sheet: manages the busy flag and error
/// message around the repository call.
class SubmitBidController extends ChangeNotifier {
  SubmitBidController(this._bids);

  final BidRepository _bids;

  bool _busy = false;
  String? _errorMessage;

  bool get isBusy => _busy;
  String? get errorMessage => _errorMessage;

  /// Submits the bid; returns true on success so the sheet can close.
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
