import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_widgets.dart';
import '../data/user_admin_repository.dart';
import '../domain/managed_user.dart';

/// Admin Home › Users tab: search every user and suspend / reinstate them.
/// Suspension is a soft ban applied by the `setUserSuspended` Cloud Function -
/// the user keeps their account but is frozen out of all actions and locked to
/// the "account suspended" screen until reinstated. Admins are never listed
/// (they can't be suspended). Hosted (Scaffold and all) by AdminHomeScreen.
class ManageUsersScreen extends StatefulWidget {
  const ManageUsersScreen({super.key});

  @override
  State<ManageUsersScreen> createState() => _ManageUsersScreenState();
}

class _ManageUsersScreenState extends State<ManageUsersScreen> {
  // Cached so typing in the search box re-filters the loaded list client-side
  // instead of resubscribing to Firestore on every keystroke.
  late final Stream<List<ManagedUser>> _users =
      context.read<UserAdminRepository>().watchUsers();

  String _query = '';
  String? _busyUid; // the user whose suspend/reinstate call is in flight

  /// Opens the reason sheet; on confirm applies the suspension. The sheet
  /// returns the reason string (possibly empty) on Suspend, or null when
  /// cancelled/dismissed - so it owns and disposes its own controller.
  Future<void> _suspend(ManagedUser user) async {
    final reason = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _SuspendSheet(userName: user.displayName),
    );
    if (reason == null || !mounted) return;
    await _apply(user.uid, suspended: true, reason: reason);
  }

  Future<void> _reinstate(ManagedUser user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reinstate ${user.displayName}?'),
        content: const Text('They will regain full access to the marketplace.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Reinstate')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _apply(user.uid, suspended: false);
  }

  Future<void> _apply(String uid,
      {required bool suspended, String? reason}) async {
    setState(() => _busyUid = uid);
    try {
      await context.read<UserAdminRepository>().setSuspended(
          uid: uid, suspended: suspended, reason: reason);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(suspended ? 'User suspended.' : 'User reinstated.')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not update the user. Please try again.')));
    } finally {
      if (mounted) setState(() => _busyUid = null);
    }
  }

  /// Confirms, then clears every second factor from [user] - the recovery
  /// path for a lost authenticator app.
  Future<void> _clearMfa(ManagedUser user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reset two-factor for ${user.displayName}?'),
        content: const Text(
            'This lets them sign in with just their password until they set '
            'it up again.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Reset')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busyUid = user.uid);
    try {
      await context.read<UserAdminRepository>().clearMfa(user.uid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Two-factor authentication reset.')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not reset it. Please try again.')));
    } finally {
      if (mounted) setState(() => _busyUid = null);
    }
  }

  /// Non-admin users matching the search, suspended ones first then by name.
  List<ManagedUser> _visible(List<ManagedUser> all) {
    final q = _query.trim().toLowerCase();
    final list = [
      for (final u in all)
        if (u.role != 'admin' &&
            (q.isEmpty ||
                u.displayName.toLowerCase().contains(q) ||
                (u.email ?? '').toLowerCase().contains(q)))
          u,
    ];
    list.sort((a, b) {
      if (a.suspended != b.suspended) return a.suspended ? -1 : 1;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Users', style: theme.textTheme.headlineMedium),
              const SizedBox(height: 4),
              Text('Search users and suspend or reinstate their accounts.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 16),
              TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search by name or email',
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<List<ManagedUser>>(
            stream: _users,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: AppCard(
                    child: EmptyState(
                      icon: Icons.error_outline,
                      title: "Couldn't load users",
                      message: 'Check your connection and try again.',
                    ),
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final users = _visible(snapshot.data!);
              if (users.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: AppCard(
                    child: EmptyState(
                      icon: Icons.person_search_outlined,
                      title: 'No users found',
                      message: 'No users match your search.',
                    ),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                itemCount: users.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _UserCard(
                    user: users[i],
                    busy: _busyUid == users[i].uid,
                    onSuspend: () => _suspend(users[i]),
                    onReinstate: () => _reinstate(users[i]),
                    onClearMfa: () => _clearMfa(users[i]),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// One user row with a suspend / reinstate action.
class _UserCard extends StatelessWidget {
  const _UserCard({
    required this.user,
    required this.busy,
    required this.onSuspend,
    required this.onReinstate,
    required this.onClearMfa,
  });

  final ManagedUser user;
  final bool busy;
  final VoidCallback onSuspend;
  final VoidCallback onReinstate;
  final VoidCallback onClearMfa;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isProvider = user.role == 'provider';
    return AppCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: context.fairbid.subtleBlue,
            backgroundImage: user.photoUrl != null
                ? ResizeImage(NetworkImage(user.photoUrl!),
                    width: (48 * MediaQuery.devicePixelRatioOf(context))
                        .round())
                : null,
            child: user.photoUrl == null
                ? Icon(
                    isProvider
                        ? Icons.handyman_outlined
                        : Icons.person_outline,
                    color: context.fairbid.verified)
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(user.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                if (user.email != null) ...[
                  const SizedBox(height: 2),
                  Text(user.email!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    PillBadge(
                      label: isProvider ? 'Provider' : 'Requestor',
                      icon: isProvider
                          ? Icons.handyman_outlined
                          : Icons.person_outline,
                      color: isProvider
                          ? context.fairbid.verified
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    if (user.suspended)
                      PillBadge(
                        label: 'Suspended',
                        icon: Icons.block,
                        color: context.fairbid.danger,
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (busy)
            const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2))
          else ...[
            PopupMenuButton<String>(
              tooltip: 'More actions',
              onSelected: (value) {
                if (value == 'mfa') onClearMfa();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'mfa', child: Text('Reset two-factor')),
              ],
            ),
            if (user.suspended)
              OutlinedButton(
                onPressed: onReinstate,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                child: const Text('Reinstate'),
              )
            else
              OutlinedButton(
                onPressed: onSuspend,
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.fairbid.danger,
                  side: BorderSide(color: context.fairbid.danger),
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                child: const Text('Suspend'),
              ),
          ],
        ],
      ),
    );
  }
}

/// The suspend-reason bottom sheet. A StatefulWidget so it owns and disposes
/// its own TextEditingController (the sheet outlives the caller's await during
/// the close animation). Pops the trimmed reason (possibly empty) on Suspend,
/// or null when cancelled/dismissed.
class _SuspendSheet extends StatefulWidget {
  const _SuspendSheet({required this.userName});

  final String userName;

  @override
  State<_SuspendSheet> createState() => _SuspendSheetState();
}

class _SuspendSheetState extends State<_SuspendSheet> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Suspend ${widget.userName}?',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('They will be blocked from every action (posting, '
                'bidding, payments, chat, reviews) until reinstated.'),
            const SizedBox(height: 16),
            TextField(
              controller: _reason,
              decoration: const InputDecoration(
                labelText: 'Reason (optional)',
                hintText: 'Shown to the user',
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () =>
                        Navigator.of(context).pop(_reason.text.trim()),
                    child: const Text('Suspend'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
