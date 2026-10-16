import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/keyed_stream_builder.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../notifications/data/notification_repository.dart';

/// What:   Top bar shared by the main tabs.
/// Input:  Signed-in uid; NotificationRepository.watchUnreadCount() (notification_repository.dart).
/// Output: Wordmark and a bell with an unread badge that opens `/notifications`.
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

/// What:   Notification bell with an unread count badge.
/// Input:  [uid]; NotificationRepository.watchUnreadCount(uid) (notification_repository.dart).
/// Output: Plain bell when signed out; otherwise a badge shown only when the count is above zero.
class _BellIcon extends StatelessWidget {
  const _BellIcon({required this.uid});
  final String? uid;

  @override
  Widget build(BuildContext context) {
    final id = uid;
    const icon = Icon(Icons.notifications_none_rounded);
    if (id == null) return icon;
    return KeyedStreamBuilder<int>(
      cacheKey: id,
      create: () => context.read<NotificationRepository>().watchUnreadCount(id),
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
