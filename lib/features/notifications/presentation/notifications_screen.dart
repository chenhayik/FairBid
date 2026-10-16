import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/time_ago.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/notification_repository.dart';
import '../domain/app_notification.dart';

/// What:   Notification centre opened from the app bar bell.
/// Input:  NotificationRepository.watchMine(uid) (notification_repository.dart).
/// Output: Feed newest first with unread rows tinted; tapping marks read and follows the deep link.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  // Created once so rebuilds don't resubscribe.
  Stream<List<AppNotification>>? _notifications;
  String? _uid;

  @override
  void initState() {
    super.initState();
    _uid = context.read<AuthController>().user?.uid;
    if (_uid != null) {
      _notifications =
          context.read<NotificationRepository>().watchMine(_uid!);
    }
  }

  /// What:   Opens a tapped notification.
  /// Input:  [notification] with its optional `route`.
  /// Output: Marks it read in the background, then pushes its route when set.
  Future<void> _open(AppNotification notification) async {
    // Fire-and-forget: navigation shouldn't wait.
    if (!notification.read) {
      context
          .read<NotificationRepository>()
          .markRead(_uid!, notification.id)
          .catchError((_) {});
    }
    final route = notification.route;
    if (route != null && route.isNotEmpty) context.push(route);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          TextButton(
            onPressed: _uid == null
                ? null
                : () => context
                    .read<NotificationRepository>()
                    .markAllRead(_uid!)
                    .catchError((_) {}),
            child: const Text('Mark all read'),
          ),
        ],
      ),
      body: SafeArea(
        child: _uid == null
            ? const Center(child: CircularProgressIndicator())
            : StreamBuilder<List<AppNotification>>(
                stream: _notifications,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return const EmptyState(
                      icon: Icons.error_outline,
                      title: "Couldn't load notifications",
                      message: 'Please check your connection and try again.',
                    );
                  }
                  final items = snapshot.data ?? [];
                  if (items.isEmpty) {
                    return const EmptyState(
                      icon: Icons.notifications_none_rounded,
                      title: 'Nothing yet',
                      message: 'Bids, messages, payments and job updates '
                          'will appear here.',
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.all(24),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, i) => _NotificationTile(
                      notification: items[i],
                      onTap: () => _open(items[i]),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

/// What:   One row: type icon, title, body and time; unread rows are tinted.
/// Input:  [notification]; [onTap] callback.
/// Output: AppCard with the blue tint and bold title when unread.
class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.notification, required this.onTap});
  final AppNotification notification;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unread = !notification.read;

    return AppCard(
      onTap: onTap,
      color: unread ? context.fairbid.subtleBlue : null,
      padding: const EdgeInsets.all(16),
      child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(notification.type.icon,
                size: 22,
                color: unread
                    ? context.fairbid.verified
                    : theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          notification.title,
                          style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight:
                                  unread ? FontWeight.w600 : FontWeight.w500),
                        ),
                      ),
                      Text(
                        timeAgo(notification.createdAt),
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    notification.body,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
      ),
    );
  }
}
