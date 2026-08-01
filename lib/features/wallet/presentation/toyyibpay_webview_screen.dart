import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// What happened in the [ToyyibpayWebViewScreen], popped back to the caller
/// as a **messaging hint only**. The redirect is NEVER trusted as proof of
/// payment: the server reconcile (`WalletRepository.reconcileTopUp`), backed
/// by the `toyyibpayCallback` webhook, remains the sole source of truth for
/// whether the wallet was actually credited. This only tells the caller
/// which copy to show while that reconcile runs.
enum ToyyibpayReturnStatus {
  /// The user dismissed the page (✕ or system back) before the browser ever
  /// reached toyyibPay's return URL — most likely no payment was attempted,
  /// so the caller should skip reconciling altogether.
  cancelled,

  /// The return URL's `status_id=1`: toyyibPay reports the payment succeeded.
  success,

  /// The return URL's `status_id=2`: toyyibPay reports the payment pending.
  pending,

  /// The return URL's `status_id=3`, or a return URL with no recognised
  /// `status_id`: toyyibPay reports the payment failed.
  failed;

  /// Maps toyyibPay's `status_id` return-URL query param to a status. Falls
  /// back to [failed] for `"3"` and for anything unrecognised, since the
  /// return URL was reached either way (a payment attempt did happen).
  static ToyyibpayReturnStatus fromStatusId(String? statusId) {
    switch (statusId) {
      case '1':
        return ToyyibpayReturnStatus.success;
      case '2':
        return ToyyibpayReturnStatus.pending;
      default:
        return ToyyibpayReturnStatus.failed;
    }
  }
}

/// Hosts toyyibPay's sandbox payment page for one bill. This is a UX
/// convenience only: it pops with a [ToyyibpayReturnStatus] once either the
/// browser is redirected to the return URL (carrying a status hint parsed
/// from `status_id`) or the user closes it manually via the ✕ or system back
/// ([ToyyibpayReturnStatus.cancelled]) — but that result is never trusted as
/// proof of payment. The `toyyibpayCallback` Cloud Function — and, as a
/// backstop, `WalletRepository.reconcileTopUp` called by the caller after
/// this screen pops — are the sole source of truth for whether the wallet
/// was actually credited.
class ToyyibpayWebViewScreen extends StatefulWidget {
  const ToyyibpayWebViewScreen({super.key, required this.paymentUrl});

  final String paymentUrl;

  @override
  State<ToyyibpayWebViewScreen> createState() =>
      _ToyyibpayWebViewScreenState();
}

class _ToyyibpayWebViewScreenState extends State<ToyyibpayWebViewScreen> {
  // The browser redirect toyyibPay sends payers to after a payment attempt.
  // It doesn't need to resolve to a real page — this screen intercepts it.
  static const _returnUrlPrefix = 'https://fairbid-c9340.web.app/payment-return';

  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          if (request.url.startsWith(_returnUrlPrefix)) {
            if (mounted) {
              final statusId =
                  Uri.tryParse(request.url)?.queryParameters['status_id'];
              Navigator.of(context)
                  .pop(ToyyibpayReturnStatus.fromStatusId(statusId));
            }
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(Uri.parse(widget.paymentUrl));
  }

  /// The user backed out (✕ or system back) without the browser ever
  /// reaching the return URL.
  void _cancel() => Navigator.of(context).pop(ToyyibpayReturnStatus.cancelled);

  @override
  Widget build(BuildContext context) {
    return PopScope<ToyyibpayReturnStatus>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Complete Payment'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: _cancel,
          ),
        ),
        body: WebViewWidget(controller: _controller),
      ),
    );
  }
}
