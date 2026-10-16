import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/config/platform_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/util/money.dart';
import '../../../core/util/payment_log.dart';
import '../../../core/util/time_ago.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../auth/domain/user_role.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../auth/presentation/reauth_dialog.dart';
import '../../jobs/data/job_repository.dart';
import '../../jobs/data/milestone_repository.dart';
import '../../jobs/domain/job.dart';
import '../../jobs/domain/milestone.dart';
import '../../wallet/data/wallet_repository.dart';
import '../../wallet/domain/ledger_entry.dart';
import '../../wallet/domain/payout_method.dart';
import '../../wallet/presentation/payout_method_screen.dart';
import '../../wallet/presentation/toyyibpay_webview_screen.dart';
import '../../wallet/presentation/wallet_amount_sheet.dart';

/// What:   Wallet screen: Earnings & payouts for providers, My wallet for requestors.
/// Input:  WalletRepository (ledger, payout method), MilestoneRepository / JobRepository for escrow figures.
/// Output: Providers: Available with Withdraw, In escrow, Total earnings, payout method. Requestors: toyyibPay (sandbox) Top Up, optional demo top-up, held-in-escrow card. Both: transaction history.
class EarningsScreen extends StatefulWidget {
  const EarningsScreen({super.key});

  @override
  State<EarningsScreen> createState() => _EarningsScreenState();
}

class _EarningsScreenState extends State<EarningsScreen> {
  // Created once so rebuilds don't resubscribe.
  Stream<List<LedgerEntry>>? _transactions;
  Stream<List<Milestone>>? _milestones;

  /// Where withdrawals go; null until set up.
  PayoutMethod? _payout;

  /// The client's own jobs, to show how much is held for them.
  Stream<List<Job>>? _myJobs;
  StreamSubscription<PayoutMethod?>? _payoutSub;

  @override
  void dispose() {
    _payoutSub?.cancel();
    super.dispose();
  }

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
    } else if (user.role == UserRole.requestor) {
      _myJobs = context.read<JobRepository>().watchMyJobs(user.uid);
    }
    if (user.role != UserRole.admin) {
      _payoutSub = context
          .read<WalletRepository>()
          .watchPayoutMethod(user.uid)
          .listen((m) => setState(() => _payout = m));
    }
  }

  /// What:   Asks the provider to add a payout method before the first withdrawal.
  /// Input:  None.
  /// Output: Confirm dialog; Add opens PayoutMethodScreen.
  Future<void> _askForPayoutMethod() async {
    final add = await showConfirmDialog(
      context,
      title: 'Where should we send it?',
      body: 'Add a DuitNow ID or bank account before your first withdrawal.',
      cancelLabel: 'Not now',
      actionLabel: 'Add payout method',
    );
    if (add && mounted) await PayoutMethodScreen.open(context);
  }

  /// What:   Re-reads the profile so Available reflects a new balance at once.
  /// Input:  AuthController.refreshUser().
  /// Output: Refreshed AppUser.walletBalanceSen for the card.
  Future<void> _refreshBalance() =>
      context.read<AuthController>().refreshUser();

  /// What:   Withdraws from the available balance.
  /// Input:  [balanceSen], the available balance, as the maximum; the payout method from WalletRepository.watchPayoutMethod().
  /// Output: Asks for a payout method if none, blocks while it is on hold, then re-auth, amount sheet and WalletRepository.withdraw().
  /// Notes:  Re-auth is a step-up so an unlocked stolen phone cannot drain the wallet.
  Future<void> _withdraw(int balanceSen) async {
    final user = context.read<AuthController>().user;
    if (user == null) return;
    final payout = _payout;
    if (payout == null) return _askForPayoutMethod();
    if (payout.onHold()) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('You changed your payout method, so withdrawals '
              'resume ${DateFormat('d MMM, h:mm a').format(payout.availableAt!)}.')));
      return;
    }

    // Step-up auth: an unlocked stolen phone shouldn't drain the wallet.
    final confirmed = await ReauthDialog.show(
      context,
      user: user,
      message: 'For your security, confirm your password before withdrawing.',
      actionLabel: 'Continue',
    );
    if (!confirmed || !mounted) return;

    final wallet = context.read<WalletRepository>();
    int? amountSen;
    final ok = await WalletAmountSheet.show(
      context,
      title: 'Withdraw',
      subtitle: 'Sent to ${payout.masked}. Demo: no real transfer is made.',
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
              '${formatRm(amountSen ?? 0)} sent to ${payout.masked} (demo).')));
    }
  }

  /// What:   Tops up the requestor's wallet through toyyibPay (sandbox).
  /// Input:  Amount from WalletAmountSheet; WalletRepository.createTopUpBill() and reconcileTopUp().
  /// Output: Opens the bill in a WebView, then reconciles with the server and shows a result snackbar.
  /// Notes:  The WebView status only picks the copy; reconcileTopUp decides whether money moved (a backstop for a missed webhook).
  Future<void> _topUp() async {
    final wallet = context.read<WalletRepository>();
    String? billCode;
    String? paymentUrl;
    int? amountSen;
    final ok = await WalletAmountSheet.show(
      context,
      title: 'Top up wallet',
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

    // Backed out before the return URL: nothing to reconcile (it would read as a false alarm).
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
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
          (e is FirebaseFunctionsException ? e.message : null) ??
              "Couldn't confirm your payment. If you were charged, it will "
                  'appear in your transaction history automatically once '
                  "processed. Don't pay again.")));
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
      message = 'Payment not confirmed yet. It will appear in your '
          "transaction history automatically once processed. Don't pay again.";
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// What:   Demo top-up for testing without the real gateway.
  /// Input:  Amount from WalletAmountSheet; WalletRepository.topUp().
  /// Output: Refreshes the balance and shows an "added to your wallet" snackbar.
  Future<void> _topUpDemo() async {
    final wallet = context.read<WalletRepository>();
    int? amountSen;
    final ok = await WalletAmountSheet.show(
      context,
      title: 'Demo top up',
      subtitle: 'Demo top-up: this stands in for a payment gateway.',
      actionLabel: 'Top up',
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
          AppBar(title: Text(isProvider ? 'Earnings & payouts' : 'My wallet')),
      body: SafeArea(
        // Pull-to-refresh is mostly reassurance (the data is live) but is expected right after paying.
        child: RefreshIndicator(
          onRefresh: _refreshBalance,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(24),
            children: [
            _AvailableCard(
              balanceSen: user.walletBalanceSen,
              actionLabel: isProvider ? 'Withdraw' : 'Top up',
              onAction: isProvider
                  ? () => _withdraw(user.walletBalanceSen)
                  : _topUp,
            ),
            if (!isProvider && PlatformConfig.demoTopUpEnabled) ...[
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
            ] else ...[
              const SizedBox(height: 8),
              // Refunds land here, so clients can take money back out too.
              SecondaryButton(
                label: 'Withdraw',
                onPressed: () => _withdraw(user.walletBalanceSen),
              ),
              const SizedBox(height: 16),
              _HeldForJobsCard(stream: _myJobs),
            ],
            const SizedBox(height: 16),
            _PayoutMethodCard(
              method: _payout,
              onEdit: () => PayoutMethodScreen.open(context),
            ),
            const SizedBox(height: 16),
            _TransactionHistoryCard(stream: _transactions, myUid: user.uid),
            ],
          ),
        ),
      ),
    );
  }
}

/// What:   Available balance with its action button.
/// Input:  [balanceSen]; [actionLabel] (Withdraw or Top up); [onAction] callback.
/// Output: AppCard with the amount and a primary button.
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

/// What:   In Escrow (funded and submitted) and Total Earnings (released), summed from the provider's milestones.
/// Input:  [stream] from MilestoneRepository.watchProviderMilestones() (milestone_repository.dart).
/// Output: Two StatCards; dashes while loading so RM 0.00 is not shown as fact.
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
        // Dashes while loading, so RM 0.00 isn't shown as fact.
        final loading = snapshot.connectionState == ConnectionState.waiting;
        final milestones = loading ? const <Milestone>[] : snapshot.data ?? [];
        int inEscrowSen = 0, earnedSen = 0;
        for (final m in milestones) {
          switch (m.status) {
            case MilestoneStatus.funded || MilestoneStatus.submitted:
              inEscrowSen += m.amountSen;
            // `resolved` only exists on legacy dispute wins.
            case MilestoneStatus.released || MilestoneStatus.resolved:
              earnedSen += m.amountSen;
            default:
              break;
          }
        }
        String show(int sen) => loading ? '-' : formatRm(sen);
        return Column(
          children: [
            StatCard(
              label: 'In escrow',
              value: show(inEscrowSen),
              icon: Icons.lock_outline,
            ),
            const SizedBox(height: 12),
            StatCard(label: 'Total earnings', value: show(earnedSen)),
          ],
        );
      },
    );
  }
}

/// What:   Money a client has in escrow for in-progress jobs.
/// Input:  [stream] from JobRepository.watchMyJobs() (job_repository.dart).
/// Output: StatCard with the sum of accepted bid amounts for in-progress jobs, since a job is paid in full at award.
class _HeldForJobsCard extends StatelessWidget {
  const _HeldForJobsCard({required this.stream});
  final Stream<List<Job>>? stream;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Job>>(
      stream: stream,
      builder: (context, snapshot) {
        // A job is paid in full at award and holds its whole price until released.
        final heldSen = (snapshot.data ?? const <Job>[])
            .where((j) => j.status == JobStatus.inProgress)
            .fold<int>(0, (sum, j) => sum + (j.acceptedBidAmountSen ?? 0));
        return StatCard(
          label: 'Held in escrow for your jobs',
          value: snapshot.hasData ? formatRm(heldSen) : '-',
          icon: Icons.lock_outline,
        );
      },
    );
  }
}

/// What:   The provider's payout method with an Add or Change button.
/// Input:  [method] from WalletRepository.watchPayoutMethod(); [onEdit] callback.
/// Output: Masked account and holder name, or a "Not set up yet" note.
class _PayoutMethodCard extends StatelessWidget {
  const _PayoutMethodCard({required this.method, required this.onEdit});

  final PayoutMethod? method;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final m = method;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Payout method', style: theme.textTheme.titleLarge),
              ),
              TextButton(
                onPressed: onEdit,
                child: Text(m == null ? 'Add' : 'Change'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (m == null)
            Text('Not set up yet. Add a DuitNow ID or bank account before '
                'your first withdrawal.', style: muted)
          else
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: context.fairbid.subtleBlue,
                  child: Icon(
                    m.isDuitNow ? Icons.qr_code_2 : Icons.account_balance,
                    color: context.fairbid.verified,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.masked, style: theme.textTheme.bodyLarge),
                      Text(m.holderName, style: muted),
                      if (m.onHold())
                        Text(
                          'Usable from '
                          '${DateFormat('d MMM, h:mm a').format(m.availableAt!)}'
                          ' (24-hour safety hold).',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: context.fairbid.warningText),
                        ),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// What:   The user's ledger as a list.
/// Input:  [stream] from WalletRepository.watchMyTransactions() (wallet_repository.dart); [myUid].
/// Output: _TransactionRow per entry, or loading, error and empty states.
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
          Text('Transaction history', style: theme.textTheme.titleLarge),
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
              // Loading before empty, so "No transactions yet" isn't asserted early.
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
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

/// What:   One ledger row: type icon, label, job and time, and a signed amount.
/// Input:  [entry]; [myUid] decides if it is a credit.
/// Output: Green "+" amount when money came into [myUid]'s wallet, otherwise "−".
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
      LedgerType.refund => Icons.undo_rounded,
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
                  ? context.fairbid.successText
                  : theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
