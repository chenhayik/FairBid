import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../features/auth/presentation/auth_controller.dart';
import '../../features/messages/data/chat_repository.dart';
import '../widgets/keyed_stream_builder.dart';

/// What:   Bottom-navigation frame for the four tabs (Home, My jobs, Messages, Profile).
/// Input:  [navigationShell] from go_router's StatefulShellRoute; unread count via ChatRepository.watchTotalUnread().
/// Output: NavigationBar with a Messages badge; each tab keeps its state.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  void _goToTab(int index) {
    // Re-tapping the active tab resets it.
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
            label: 'My jobs',
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

/// Messages tab icon with an unread badge.
class _MessagesIcon extends StatelessWidget {
  const _MessagesIcon({required this.uid, required this.icon});
  final String? uid;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final id = uid;
    if (id == null) return Icon(icon);
    return KeyedStreamBuilder<int>(
      cacheKey: id,
      create: () => context.read<ChatRepository>().watchTotalUnread(id),
      builder: (context, snapshot) {
        final unread = snapshot.data ?? 0;
        return Badge.count(
          count: unread,
          isLabelVisible: unread > 0,
          child: Icon(icon),
        );
      },
    );
  }
}
