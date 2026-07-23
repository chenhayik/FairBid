import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Hosts toyyibPay's sandbox payment page for one bill. This is a UX
/// convenience only: it pops as soon as the browser is redirected to the
/// return URL (or the user closes it manually), but that redirect is never
/// trusted as proof of payment. The `toyyibpayCallback` Cloud Function — and,
/// as a backstop, `WalletRepository.reconcileTopUp` called by the caller
/// after this screen pops — are the sole source of truth for whether the
/// wallet was actually credited.
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
            if (mounted) Navigator.of(context).pop();
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(Uri.parse(widget.paymentUrl));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Complete Payment'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}
