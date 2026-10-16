import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_widgets.dart';
import '../data/user_admin_repository.dart';
import '../domain/managed_user.dart';

/// What:   Admin Users tab: search users, suspend / reinstate them, reset their two-factor.
/// Input:  Users via UserAdminRepository.watchUsers() (user_admin_repository.dart); admins are hidden.
/// Output: Filtered list; actions call `setUserSuspended` / `adminClearMfa`. Hosted by AdminHomeScreen.
class ManageUsersScreen extends StatefulWidget {
  const ManageUsersScreen({super.key});

  @override
  State<ManageUsersScreen> createState() => _ManageUsersScreenState();
}

class _ManageUsersScreenState extends State<ManageUsersScreen> {
  // Created once so typing re-filters client-side without resubscribing.
  late final Stream<List<ManagedUser>> _users =
      context.read<UserAdminRepository>().watchUsers();

  String _query = '';
  String? _busyUid; // the user whose action is in flight

  /// What:   Suspends [user] after the admin enters an optional reason.
  /// Input:  [user] from the list; reason from the _SuspendSheet (null = cancelled).
  /// Output: Calls UserAdminRepository.setSuspended(suspended: true) via _act.
  Future<void> _suspend(ManagedUser user) async {
    final reason = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _SuspendSheet(userName: user.displayName),
    );
    if (reason == null || !mounted) return;
    await _act(
      user.uid,
      () => context
          .read<UserAdminRepository>()
          .setSuspended(uid: user.uid, suspended: true, reason: reason),
      done: 'User suspended.',
      failed: 'Could not update the user. Please try again.',
    );
  }

  /// What:   Reinstates a suspended [user] after a confirm dialog.
  /// Input:  [user] from the list.
  /// Output: Calls UserAdminRepository.setSuspended(suspended: false) via _act.
  Future<void> _reinstate(ManagedUser user) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Reinstate ${user.displayName}?',
      body: 'They will regain full access to the marketplace.',
      actionLabel: 'Reinstate',
    );
    if (!confirmed || !mounted) return;
    await _act(
      user.uid,
      () => context
          .read<UserAdminRepository>()
          .setSuspended(uid: user.uid, suspended: false),
      done: 'User reinstated.',
      failed: 'Could not update the user. Please try again.',
    );
  }

  /// What:   Runs one admin action on a user with a busy marker and result snackbar.
  /// Input:  [uid] of the user; [call] to run; [done] / [failed] snackbar texts.
  /// Output: Sets _busyUid while [call] runs, then shows [done] or [failed].
  Future<void> _act(
    String uid,
    Future<void> Function() call, {
    required String done,
    required String failed,
  }) async {
    setState(() => _busyUid = uid);
    try {
      await call();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failed)));
    } finally {
      if (mounted) setState(() => _busyUid = null);
    }
  }

  /// What:   Resets [user]'s two-factor after a confirm dialog (lost authenticator recovery).
  /// Input:  [user] from the list.
  /// Output: Calls UserAdminRepository.clearMfa(uid) via _act.
  Future<void> _clearMfa(ManagedUser user) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Reset two-factor for ${user.displayName}?',
      body: 'This lets them sign in with just their password until they set '
          'it up again.',
      actionLabel: 'Reset',
    );
    if (!confirmed || !mounted) return;
    await _act(
      user.uid,
      () => context.read<UserAdminRepository>().clearMfa(user.uid),
      done: 'Two-factor authentication reset.',
      failed: 'Could not reset it. Please try again.',
    );
  }

  /// What:   Users the list should show.
  /// Input:  [all] users from the stream; the search text in _query.
  /// Output: Non-admins matching the query on name or email, suspended first then by name.
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

/// What:   One user row with avatar, role and suspended pills, the suspend / reinstate button and a more-actions menu.
/// Input:  [user]; [busy] while an action runs; [onSuspend], [onReinstate], [onClearMfa] callbacks.
/// Output: AppCard; a spinner replaces the actions while [busy].
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
            OutlinedButton(
              onPressed: user.suspended ? onReinstate : onSuspend,
              style: OutlinedButton.styleFrom(
                foregroundColor: user.suspended ? null : context.fairbid.danger,
                side: user.suspended
                    ? null
                    : BorderSide(color: context.fairbid.danger),
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              child: Text(user.suspended ? 'Reinstate' : 'Suspend'),
            ),
          ],
        ],
      ),
    );
  }
}

/// What:   Bottom sheet asking for an optional suspension reason.
/// Input:  [userName] of the user being suspended.
/// Output: Pops the trimmed reason on Suspend, null on Cancel.
/// Notes:  Stateful so it disposes its own text controller after the close animation.
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
