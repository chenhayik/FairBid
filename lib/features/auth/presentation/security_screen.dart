import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_widgets.dart';
import '../data/auth_exception.dart';
import '../domain/mfa.dart';
import 'auth_controller.dart';
import 'reauth_dialog.dart';

/// What:   Profile > Security screen to turn two-factor authentication on or off.
/// Input:  [AuthController] (enrolled factors, TOTP enrolment, unenrol).
/// Output: Status or setup card; enrolment runs here because the TOTP secret lives in memory only.
/// Notes:  Also the forced `/setup-2fa` screen for providers and admins, who cannot turn 2FA off.
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  late Future<List<MfaFactor>> _factors;

  /// Non-null while setting up 2FA.
  TotpEnrollment? _enrollment;
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _factors = context.read<AuthController>().enrolledFactors();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  /// What:   Resets the setup state and re-reads the enrolled factors.
  /// Input:  AuthController.enrolledFactors().
  /// Output: Clears the enrolment, error and code; refreshes the factors future.
  void _reload() {
    setState(() {
      _enrollment = null;
      _error = null;
      _code.clear();
      _factors = context.read<AuthController>().enrolledFactors();
    });
  }

  /// What:   Begins two-factor setup after re-confirming the password.
  /// Input:  ReauthDialog; AuthController.startTotpEnrollment().
  /// Output: Stores the TOTP enrolment so the QR / key card shows; or an inline error.
  Future<void> _startSetup() async {
    final auth = context.read<AuthController>();
    final user = auth.user;
    if (user == null) return;

    final confirmed = await ReauthDialog.show(
      context,
      user: user,
      message: 'Confirm your password to set up two-factor authentication.',
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final enrollment = await auth.startTotpEnrollment();
      if (!mounted) return;
      setState(() {
        _enrollment = enrollment;
        _busy = false;
      });
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  /// What:   Completes setup with the 6-digit code from the authenticator app.
  /// Input:  The code field and the stored enrolment; AuthController.completeTotpEnrollment().
  /// Output: Reloads and shows "Two-factor authentication is on."; on failure shows the error and clears the code.
  Future<void> _finishSetup() async {
    final enrollment = _enrollment;
    if (enrollment == null) return;
    if (_code.text.length != 6) {
      setState(() => _error = 'Enter the 6-digit code.');
      return;
    }
    final auth = context.read<AuthController>();
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await auth.completeTotpEnrollment(
      enrollment: enrollment,
      code: _code.text,
    );
    if (!mounted) return;
    if (ok) {
      _reload();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Two-factor authentication is on.')));
      return;
    }
    setState(() {
      _busy = false;
      _error = auth.errorMessage ?? 'Could not verify that code.';
      _code.clear();
    });
  }

  /// What:   Removes [factor] after a confirm dialog.
  /// Input:  [factor] from AuthController.enrolledFactors().
  /// Output: AuthController.unenrollFactor(), then reloads; or an inline error.
  Future<void> _turnOff(MfaFactor factor) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Turn off two-factor?',
      body: 'Your account will be protected by your password alone. You can '
          'turn it back on at any time.',
      actionLabel: 'Turn off',
      danger: true,
    );
    if (!confirmed || !mounted) return;

    final auth = context.read<AuthController>();
    final ok = await auth.unenrollFactor(factor.uid);
    if (!mounted) return;
    if (ok) {
      _reload();
      return;
    }
    setState(() => _error = auth.errorMessage);
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthController>().user;
    final forced = user?.needsTwoFactor ?? false;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Security'),
        // The forced setup has no way back, so let the user leave.
        actions: [
          if (forced)
            TextButton(
              onPressed: () => context.read<AuthController>().signOut(),
              child: const Text('Sign out'),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (_error != null) ErrorBanner(_error!),
            if (forced)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text('Service providers and admins must turn on '
                    'two-factor authentication before using FairBid.'),
              ),
            // Unverified users never get here: the router holds them on /verify-email.
            if (_enrollment != null)
              _SetupCard(
                enrollment: _enrollment!,
                code: _code,
                busy: _busy,
                onSubmit: _finishSetup,
                onCancel: _reload,
              )
            else
              FutureBuilder<List<MfaFactor>>(
                future: _factors,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final factor = snapshot.data?.isNotEmpty == true
                      ? snapshot.data!.first
                      : null;
                  return _StatusCard(
                    factor: factor,
                    busy: _busy,
                    onTurnOn: _startSetup,
                    // Required for providers and admins, so no Turn off.
                    onTurnOff: factor == null || (user?.requiresTwoFactor ?? false)
                        ? null
                        : () => _turnOff(factor),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// What:   The On/Off status with its turn-on or turn-off action.
/// Input:  [factor] (null when off); [busy]; [onTurnOn] / [onTurnOff] callbacks (null [onTurnOff] hides Turn off).
/// Output: AppCard with the status text and one button.
class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.factor,
    required this.busy,
    required this.onTurnOn,
    required this.onTurnOff,
  });

  final MfaFactor? factor;
  final bool busy;
  final VoidCallback onTurnOn;
  final VoidCallback? onTurnOff;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final on = factor != null;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: context.fairbid.subtleBlue,
                child: Icon(on ? Icons.lock : Icons.lock_open_outlined,
                    color: context.fairbid.verified),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Two-factor authentication',
                        style: theme.textTheme.titleLarge),
                    const SizedBox(height: 2),
                    Text(
                      on
                          ? 'On - you enter a code from your authenticator '
                              'app when you sign in.'
                          : 'Add a code from an authenticator app on top of '
                              'your password.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              PillBadge(
                label: on ? 'On' : 'Off',
                icon: on ? Icons.check_circle : Icons.remove_circle_outline,
                color: on
                    ? context.fairbid.success
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (on && onTurnOff != null)
            SecondaryButton(
              label: 'Turn off',
              onPressed: busy ? null : onTurnOff,
            )
          else if (!on)
            PrimaryButton(
              label: 'Turn on',
              busy: busy,
              onPressed: onTurnOn,
            ),
        ],
      ),
    );
  }
}

/// What:   The QR, key and code panel shown during setup.
/// Input:  [enrollment] (QR URL and secret key); the [code] controller; [busy]; [onSubmit] / [onCancel] callbacks.
/// Output: AppCard with the QR, a copyable key, the code field and Verify / Cancel buttons.
class _SetupCard extends StatelessWidget {
  const _SetupCard({
    required this.enrollment,
    required this.code,
    required this.busy,
    required this.onSubmit,
    required this.onCancel,
  });

  final TotpEnrollment enrollment;
  final TextEditingController code;
  final bool busy;
  final VoidCallback onSubmit;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Scan this code', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Open Google Authenticator (or any authenticator app) and scan '
            'the code, then enter the 6 digits it shows.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          // Always white: the QR is unreadable on a dark surface.
          Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              color: Colors.white,
              child: QrImageView(
                data: enrollment.qrCodeUrl,
                version: QrVersions.auto,
                size: 200,
                backgroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text("Can't scan it? Enter this key instead:",
              style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  enrollment.secretKey,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontFamily: 'monospace'),
                ),
              ),
              IconButton(
                tooltip: 'Copy key',
                icon: const Icon(Icons.copy),
                onPressed: () async {
                  await Clipboard.setData(
                      ClipboardData(text: enrollment.secretKey));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Key copied')));
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: code,
            enabled: !busy,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(letterSpacing: 8),
            decoration: const InputDecoration(
              hintText: '000000',
              counterText: '',
            ),
            onSubmitted: (_) => onSubmit(),
          ),
          const SizedBox(height: 16),
          PrimaryButton(label: 'Verify and turn on', busy: busy, onPressed: onSubmit),
          TextButton(onPressed: busy ? null : onCancel, child: const Text('Cancel')),
        ],
      ),
    );
  }
}
