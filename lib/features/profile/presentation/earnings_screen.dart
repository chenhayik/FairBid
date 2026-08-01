import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/config/platform_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/util/money.dart';
import '../../../core/util/payment_log.dart';
import '../../../core/util/time_ago.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../auth/domain/user_role.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../jobs/data/milestone_repository.dart';
import '../../jobs/domain/milestone.dart';
import '../../wallet/data/wallet_repository.dart';
import '../../wallet/domain/ledger_entry.dart';
import '../../wallet/presentation/toyyibpay_webview_screen.dart';
import '../../wallet/presentation/wallet_amount_sheet.dart';

/// The wallet screen. Providers see Earnings & Payouts — Available (with
/// Withdraw), In Escrow and Total Earnings from their milestones, and their
/// payout method. Requestors see their wallet with a real toyyibPay
/// (sandbox) Top Up — plus a demo top-up kept around for testing without the
/// gateway. Both share the transaction history.
class EarningsScreen extends StatefulWidget {
  const EarningsScreen({super.key});

  @override
  State<EarningsScreen> createState() => _EarningsScreenState();
}

class _EarningsScreenState extends State<EarningsScreen> {
  // Cached so rebuilds don't resubscribe to Firestore.
  Stream<List<LedgerEntry>>? _transactions;
  Stream<List<Milestone>>? _milestones;

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthController>().user;
    if (user == null) return;
    _transactions =
        context.read<WalletRepository>().watchMyTransactions(user.uid);
    if (user.role == UserRole.provider) {
      _milestones =
          context.read<MilestoneRepository>().watchProviderMilestones(user.uid);
    }
  }

  /// Runs after a successful top-up/withdraw so the Available figure (read
  /// from the profile) reflects the new balance immediately.
  Future<void> _refreshBalance() =>
      context.read<AuthController>().refreshUser();

  Future<void> _withdraw(int balanceSen) async {
    final wallet = context.read<WalletRepository>();
    int? amountSen;
    final ok = await WalletAmountSheet.show(
      context,
      title: 'Withdraw',
      subtitle: 'Move money from your FairBid balance to your bank account.',
      actionLabel: 'Withdraw',
      maxSen: balanceSen,
      onSubmit: (sen) async {
        await wallet.withdraw(sen);
        amountSen = sen;
      },
    );
    if (ok == true && mounted) {
      await _refreshBalance();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '${formatRm(amountSen ?? 0)} withdrawn to your bank account.')));
    }
  }

  /// Real top-up: asks for an amount, creates a toyyibPay (sandbox) bill and
  /// opens its hosted payment page in a WebView. The wallet balance only
  /// updates once the server independently confirms the bill was paid — the
  /// WebView returning is just a UX cue, never trusted on its own — so this
  /// reconciles with the server immediately after, as a backstop for a
  /// webhook toyyibPay hasn't delivered yet. The WebView's return status is
  /// only ever used to pick which copy to show below (cancelled vs.
  /// attempted); [WalletRepository.reconcileTopUp] is the sole source of
  /// truth for whether money actually moved.
  Future<void> _topUp() async {
    final wallet = context.read<WalletRepository>();
    String? billCode;
    String? paymentUrl;
    int? amountSen;
    final ok = await WalletAmountSheet.show(
      context,
      title: 'Top Up Wallet',
      subtitle: 'Pay by FPX or online banking (toyyibPay sandbox).',
      actionLabel: 'Continue to Payment',
      maxSen: PlatformConfig.maxTopUpSen,
      onSubmit: (sen) async {
        final bill = await wallet.createTopUpBill(sen);
        billCode = bill.billCode;
        paymentUrl = bill.paymentUrl;
        amountSen = sen;
      },
    );
    if (ok != true || !mounted || paymentUrl == null) return;

    final status = await Navigator.of(context).push<ToyyibpayReturnStatus>(
      MaterialPageRoute<ToyyibpayReturnStatus>(
        builder: (_) => ToyyibpayWebViewScreen(paymentUrl: paymentUrl!),
      ),
    );
    if (!mounted) return;
    logPayment('topup.webview.returned',
        data: {'billCode': billCode, 'statusHint': status?.name});

    // The user backed out before the browser ever reached toyyibPay's return
    // URL: most likely nothing was attempted, so there is nothing to
    // reconcile — reconciling anyway would just report "not paid" and read
    // as a false alarm.
    if (status == null || status == ToyyibpayReturnStatus.cancelled) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Payment cancelled. Nothing was charged.')));
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Confirming payment…')));
    bool credited;
    try {
      credited = await wallet.reconcileTopUp(billCode!);
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
          e.message ??
              "Couldn't confirm your payment. If you were charged, it'll "
                  'show up in your transaction history once processed, '
                  'pull to refresh to check.')));
      return;
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              "Couldn't confirm your payment. If you were charged, it'll "
              'show up in your transaction history once processed, pull to '
              'refresh to check.')));
      return;
    }

    await _refreshBalance();
    if (!mounted) return;
    final String message;
    if (credited) {
      message = '${formatRm(amountSen ?? 0)} added to your wallet.';
    } else if (status == ToyyibpayReturnStatus.failed) {
      message = 'Payment failed. No funds were added. You can try again.';
    } else {
      message = "Payment not confirmed yet. It'll appear in your "
          'transaction history once processed, pull to refresh to check.';
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Demo-only top-up standing in for the gateway (kept for testing without
  /// driving the real toyyibPay flow); untouched by the change above.
  Future<void> _topUpDemo() async {
    final wallet = context.read<WalletRepository>();
    int? amountSen;
    final ok = await WalletAmountSheet.show(
      context,
      title: 'Demo Top Up',
      subtitle: 'Demo top-up: this stands in for a payment gateway.',
      actionLabel: 'Top Up',
      maxSen: PlatformConfig.maxTopUpSen,
      onSubmit: (sen) async {
        await wallet.topUp(sen);
        amountSen = sen;
      },
    );
    if (ok == true && mounted) {
      await _refreshBalance();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text('${formatRm(amountSen ?? 0)} added to your wallet.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthController>().user;
    if (user == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final isProvider = user.role == UserRole.provider;

    return Scaffold(
      appBar:
          AppBar(title: Text(isProvider ? 'Earnings & Payouts' : 'My Wallet')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            _AvailableCard(
              balanceSen: user.walletBalanceSen,
              actionLabel: isProvider ? 'Withdraw' : 'Top Up',
              onAction: isProvider
                  ? () => _withdraw(user.walletBalanceSen)
                  : _topUp,
            ),
            if (!isProvider) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _topUpDemo,
                  child: const Text('Use demo top-up instead'),
                ),
              ),
            ],
            if (isProvider) ...[
              const SizedBox(height: 16),
              _EscrowStats(stream: _milestones),
              const SizedBox(height: 16),
              _PayoutMethodCard(
                bankName: user.payoutBankName,
                accountLast4: user.payoutAccountLast4,
              ),
            ],
            const SizedBox(height: 16),
            _TransactionHistoryCard(stream: _transactions, myUid: user.uid),
          ],
        ),
      ),
    );
  }
}

class _AvailableCard extends StatelessWidget {
  const _AvailableCard({
    required this.balanceSen,
    required this.actionLabel,
    required this.onAction,
  });

  final int balanceSen;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: context.fairbid.subtleBlue,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('AVAILABLE',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Text(
            formatRm(balanceSen),
            style: theme.textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          PrimaryButton(
            label: actionLabel,
            trailingIcon: Icons.arrow_forward,
            onPressed: onAction,
          ),
        ],
      ),
    );
  }
}

/// In Escrow (funded + delivered milestones) and Total Earnings (released),
/// summed live from the provider's milestones across all their jobs.
class _EscrowStats extends StatelessWidget {
  const _EscrowStats({required this.stream});
  final Stream<List<Milestone>>? stream;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Milestone>>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const AppCard(
            child: EmptyState(
              icon: Icons.error_outline,
              title: "Couldn't load earnings",
              message: 'Please check your connection and try again.',
            ),
          );
        }
        final milestones = snapshot.data ?? [];
        int inEscrowSen = 0, earnedSen = 0;
        for (final m in milestones) {
          switch (m.status) {
            case MilestoneStatus.funded || MilestoneStatus.submitted:
              inEscrowSen += m.amountSen;
            // A dispute won by the provider now writes `released` (counted
            // above). `resolved` only appears on legacy documents from before
            // that change; count it here so a past dispute win still shows up.
            case MilestoneStatus.released || MilestoneStatus.resolved:
              earnedSen += m.amountSen;
            default:
              break;
          }
        }
        return Column(
          children: [
            StatCard(
              label: 'In Escrow',
              value: formatRm(inEscrowSen),
              icon: Icons.lock_outline,
            ),
            const SizedBox(height: 12),
            StatCard(label: 'Total Earnings', value: formatRm(earnedSen)),
          ],
        );
      },
    );
  }
}

class _PayoutMethodCard extends StatelessWidget {
  const _PayoutMethodCard({this.bankName, this.accountLast4});

  final String? bankName;
  final String? accountLast4;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasMethod = bankName != null && bankName!.isNotEmpty;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Payout Method', style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          if (hasMethod)
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: context.fairbid.subtleBlue,
                  child: Icon(Icons.account_balance,
                      color: context.fairbid.verified),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(bankName!, style: theme.textTheme.bodyLarge),
                      if (accountLast4 != null)
                        Text('•••• $accountLast4',
                            style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                PillBadge(
                  label: 'Verified',
                  icon: Icons.verified,
                  color: context.fairbid.verified,
                ),
              ],
            )
          else
            Text('Not set',
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _TransactionHistoryCard extends StatelessWidget {
  const _TransactionHistoryCard({required this.stream, required this.myUid});
  final Stream<List<LedgerEntry>>? stream;
  final String myUid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Transaction History', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          StreamBuilder<List<LedgerEntry>>(
            stream: stream,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const EmptyState(
                  icon: Icons.error_outline,
                  title: "Couldn't load transactions",
                  message: 'Please check your connection and try again.',
                );
              }
              final entries = snapshot.data ?? [];
              if (entries.isEmpty) {
                return const EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: 'No transactions yet',
                  message: 'Your payments and withdrawals will appear here.',
                );
              }
              return Column(
                children: [
                  for (final entry in entries)
                    _TransactionRow(entry: entry, myUid: myUid),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _TransactionRow extends StatelessWidget {
  const _TransactionRow({required this.entry, required this.myUid});
  final LedgerEntry entry;
  final String myUid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final credit = entry.isCreditFor(myUid);
    final icon = switch (entry.type) {
      LedgerType.fund => Icons.lock_outline,
      LedgerType.release => Icons.handshake_outlined,
      LedgerType.topup => Icons.add_card_outlined,
      LedgerType.withdraw => Icons.account_balance_outlined,
      LedgerType.disputeRelease ||
      LedgerType.disputeRefund =>
        Icons.gavel_rounded,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.type.label, style: theme.textTheme.bodyLarge),
                Text(
                    entry.jobTitle == null
                        ? timeAgo(entry.createdAt)
                        : '${entry.jobTitle} · ${timeAgo(entry.createdAt)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          Text(
            '${credit ? '+' : '−'}${formatRm(entry.amountSen)}',
            style: theme.textTheme.labelLarge?.copyWith(
              color: credit
                  ? context.fairbid.success
                  : theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
