import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/malaysian_banks.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/form_widgets.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/wallet_repository.dart';
import '../domain/payout_method.dart';

/// "How you get paid": a DuitNow ID or a bank account. Demo only, no real
/// bank is contacted. Pops `true` once saved.
class PayoutMethodScreen extends StatefulWidget {
  const PayoutMethodScreen({super.key});

  static Future<bool?> open(BuildContext context) =>
      context.push<bool>('/profile/payout-method');

  @override
  State<PayoutMethodScreen> createState() => _PayoutMethodScreenState();
}

class _PayoutMethodScreenState extends State<PayoutMethodScreen> {
  final _formKey = GlobalKey<FormState>();
  final _account = TextEditingController();
  final _accountAgain = TextEditingController();
  // DuitNow by mobile when there's a profile phone, else SSM or a bank.
  late final _user = context.read<AuthController>().user!;
  late final bool _hasPhone = (_user.phone ?? '').trim().isNotEmpty;
  late final bool _isBusiness = _user.providerType == 'business';
  late String _method = _hasPhone || _isBusiness ? 'duitnow' : 'bank';
  late String _proxyType = _hasPhone ? 'mobile' : 'brn';
  MalaysianBank? _bank;
  bool _busy = false;
  String? _error;

  late final Stream<PayoutMethod?> _existing = context
      .read<WalletRepository>()
      .watchPayoutMethod(context.read<AuthController>().user!.uid);

  @override
  void dispose() {
    _account.dispose();
    _accountAgain.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    // DuitNow needs an ID that is actually available on this profile.
    final phone = (context.read<AuthController>().user?.phone ?? '').trim();
    final idReady = _proxyType == 'mobile' ? phone.isNotEmpty : _isBusiness;
    if (_method == 'duitnow' && !idReady) {
      setState(() => _error = 'Add a mobile number in Edit profile first, '
          'or use a bank account.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bank = _method == 'bank';
      await context.read<WalletRepository>().savePayoutMethod(
            method: _method,
            proxyType: bank ? null : _proxyType,
            bankSwift: bank ? _bank!.swift : null,
            accountNumber: bank ? _account.text.trim() : null,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Payout method saved.')));
      context.pop(true);
    } on FirebaseFunctionsException catch (e) {
      setState(() => _error = e.message ?? 'Could not save. Try again.');
    } catch (_) {
      setState(() => _error = 'Could not save. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = context.watch<AuthController>().user!;
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final phone = (user.phone ?? '').trim();

    return Scaffold(
      appBar: AppBar(title: const Text('How you get paid')),
      body: SafeArea(
        child: StreamBuilder<PayoutMethod?>(
          stream: _existing,
          builder: (context, snapshot) {
            final existing = snapshot.data;
            return Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text(
                    'Your withdrawals go here. Demo: no real money is sent.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (existing != null) ...[
                    const SizedBox(height: 12),
                    InfoBanner(
                      icon: Icons.info_outline,
                      title: 'Now: ${existing.masked}',
                      body: 'Changing it pauses withdrawals for 24 hours, '
                          'in case someone else got into your account.',
                    ),
                  ],
                  const SizedBox(height: 20),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'duitnow', label: Text('DuitNow ID')),
                      ButtonSegment(value: 'bank', label: Text('Bank account')),
                    ],
                    selected: {_method},
                    onSelectionChanged: (s) =>
                        setState(() => _method = s.first),
                  ),
                  const SizedBox(height: 16),
                  if (_method == 'duitnow') ...[
                    Text(
                      "Works with Touch 'n Go eWallet and most banks, if the "
                      'ID is registered for DuitNow.',
                      style: muted,
                    ),
                    const SizedBox(height: 8),
                    _IdOption(
                      title: 'Mobile number',
                      subtitle: phone.isEmpty
                          ? 'Add a mobile number in Edit profile first.'
                          : '$phone (from your profile)',
                      selected: _proxyType == 'mobile',
                      onTap: phone.isEmpty
                          ? null
                          : () => setState(() => _proxyType = 'mobile'),
                    ),
                    if (_isBusiness)
                      _IdOption(
                        title: 'SSM registration number',
                        subtitle: 'For your registered business.',
                        selected: _proxyType == 'brn',
                        onTap: () => setState(() => _proxyType = 'brn'),
                      ),
                  ] else ...[
                    DropdownButtonFormField<MalaysianBank>(
                      initialValue: _bank,
                      isExpanded: true,
                      hint: const Text('Pick your bank'),
                      items: [
                        for (final b in kMalaysianBanks)
                          DropdownMenuItem(value: b, child: Text(b.name)),
                      ],
                      onChanged: (b) => setState(() => _bank = b),
                      validator: (b) => b == null ? 'Pick your bank.' : null,
                    ),
                    const SizedBox(height: 16),
                    AppTextField(
                      controller: _account,
                      label: 'Account number',
                      keyboardType: TextInputType.number,
                      validator: (v) => _bank?.checkAccount(v ?? ''),
                    ),
                    AppTextField(
                      controller: _accountAgain,
                      label: 'Account number again',
                      keyboardType: TextInputType.number,
                      validator: (v) => v?.trim() == _account.text.trim()
                          ? null
                          : "The two numbers don't match.",
                    ),
                  ],
                  const SizedBox(height: 16),
                  AppCard(
                    child: Row(
                      children: [
                        Icon(Icons.badge_outlined,
                            color: context.fairbid.verified),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Name on account',
                                  style: theme.textTheme.labelLarge),
                              Text(user.displayName ?? '',
                                  style: theme.textTheme.bodyLarge),
                              Text('The name on your profile. It must match the '
                                  'account.', style: muted),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_error != null) ErrorBanner(_error!),
                  PrimaryButton(
                    label: 'Save payout method',
                    busy: _busy,
                    onPressed: _save,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// One DuitNow ID choice, with a tick when selected.
class _IdOption extends StatelessWidget {
  const _IdOption({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: onTap != null,
      onTap: onTap,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? context.fairbid.verified : null,
      ),
      title: Text(title),
      subtitle: Text(subtitle),
    );
  }
}
