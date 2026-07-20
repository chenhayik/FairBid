import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../notifications/data/notification_repository.dart';

/// Shared top bar for the main tabs: the brand wordmark and the notifications
/// bell with a live unread badge, opening the notification centre.
class HomeAppBar extends StatelessWidget implements PreferredSizeWidget {
  const HomeAppBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final uid = context.watch<AuthController>().user?.uid;
    return AppBar(
      automaticallyImplyLeading: false,
      title: Text('FairBid',
          style: Theme.of(context)
              .textTheme
              .titleLarge
              ?.copyWith(color: context.fairbid.verified)),
      actions: [
        IconButton(
          tooltip: 'Notifications',
          icon: _BellIcon(uid: uid),
          onPressed: () => context.push('/notifications'),
        ),
      ],
    );
  }
}

/// The bell with a live unread-count badge. Stream is cached across rebuilds
/// (same pattern as the Messages tab icon) so the badge doesn't flicker.
class _BellIcon extends StatefulWidget {
  const _BellIcon({required this.uid});
  final String? uid;

  @override
  State<_BellIcon> createState() => _BellIconState();
}

class _BellIconState extends State<_BellIcon> {
  Stream<int>? _unread;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(_BellIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.uid != oldWidget.uid) _subscribe();
  }

  void _subscribe() {
    final uid = widget.uid;
    _unread = uid == null
        ? null
        : context.read<NotificationRepository>().watchUnreadCount(uid);
  }

  @override
  Widget build(BuildContext context) {
    final unreadStream = _unread;
    const icon = Icon(Icons.notifications_none_rounded);
    if (unreadStream == null) return icon;
    return StreamBuilder<int>(
      stream: unreadStream,
      builder: (context, snapshot) {
        final unread = snapshot.data ?? 0;
        return Badge.count(
          count: unread,
          isLabelVisible: unread > 0,
          child: icon,
        );
      },
    );
  }
}
