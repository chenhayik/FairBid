import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../features/auth/presentation/auth_controller.dart';
import '../../features/messages/data/chat_repository.dart';

/// The persistent bottom-navigation frame that hosts the four main tabs
/// (Home · My Jobs · Messages · Profile). The [navigationShell] is provided by
/// go_router's [StatefulShellRoute] and keeps each tab's state alive.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  void _goToTab(int index) {
    // Tapping the active tab again resets it to its initial route.
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = context.watch<AuthController>().user?.uid;
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: _goToTab,
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          const NavigationDestination(
            icon: Icon(Icons.work_outline),
            selectedIcon: Icon(Icons.work),
            label: 'My Jobs',
          ),
          NavigationDestination(
            icon: _MessagesIcon(uid: uid, icon: Icons.forum_outlined),
            selectedIcon: _MessagesIcon(uid: uid, icon: Icons.forum),
            label: 'Messages',
          ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}

/// The Messages tab icon with a live unread-count badge.
class _MessagesIcon extends StatefulWidget {
  const _MessagesIcon({required this.uid, required this.icon});
  final String? uid;
  final IconData icon;

  @override
  State<_MessagesIcon> createState() => _MessagesIconState();
}

class _MessagesIconState extends State<_MessagesIcon> {
  // Cached so rebuilds (every tab switch) don't resubscribe to Firestore and
  // flash the badge back to zero.
  Stream<int>? _unread;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(_MessagesIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.uid != oldWidget.uid) _subscribe();
  }

  void _subscribe() {
    final uid = widget.uid;
    _unread =
        uid == null ? null : context.read<ChatRepository>().watchTotalUnread(uid);
  }

  @override
  Widget build(BuildContext context) {
    final unreadStream = _unread;
    if (unreadStream == null) return Icon(widget.icon);
    return StreamBuilder<int>(
      stream: unreadStream,
      builder: (context, snapshot) {
        final unread = snapshot.data ?? 0;
        return Badge.count(
          count: unread,
          isLabelVisible: unread > 0,
          child: Icon(widget.icon),
        );
      },
    );
  }
}
