import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// What:   Outcome of the payment page, popped back as a messaging hint only.
/// Input:  The return URL's `status_id`, or the user closing the page.
/// Output: Tells the caller which copy to show; never proof of payment (the `toyyibpayCallback`
///         webhook and `WalletRepository.reconcileTopUp` decide whether the wallet is credited).
enum ToyyibpayReturnStatus {
  /// Closed before the return URL; likely no payment was attempted, so skip reconciling.
  cancelled,

  /// `status_id=1`.
  success,

  /// `status_id=2`.
  pending,

  /// `status_id=3` or unrecognised.
  failed;

  /// Maps the `status_id` query param; anything else is [failed] since an attempt did happen.
  static ToyyibpayReturnStatus fromStatusId(String? statusId) =>
      switch (statusId) {
        '1' => success,
        '2' => pending,
        _ => failed,
      };
}

/// What:   WebView hosting toyyibPay's sandbox payment page for one bill.
/// Input:  [paymentUrl] from WalletRepository.createTopUpBill() (wallet_repository.dart).
/// Output: Pops a [ToyyibpayReturnStatus] on the return redirect or on close (cancelled).
class ToyyibpayWebViewScreen extends StatefulWidget {
  const ToyyibpayWebViewScreen({super.key, required this.paymentUrl});

  final String paymentUrl;

  @override
  State<ToyyibpayWebViewScreen> createState() =>
      _ToyyibpayWebViewScreenState();
}

class _ToyyibpayWebViewScreenState extends State<ToyyibpayWebViewScreen> {
  // toyyibPay's post-payment redirect; intercepted here, so it needn't resolve to a page.
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
