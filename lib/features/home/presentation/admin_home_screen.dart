import 'package:flutter/material.dart';

import '../../admin/presentation/manage_users_screen.dart';
import '../../admin/presentation/moderation_queue_screen.dart';
import '../../admin/presentation/platform_stats_screen.dart';
import '../../admin/presentation/verification_queue_screen.dart';
import '../../disputes/presentation/dispute_queue_screen.dart';
import 'home_app_bar.dart';

/// What:   Admin Home: five tabs under the shared app bar.
/// Input:  None; hosts the verification, dispute, moderation, stats and user screens.
/// Output: TabBar plus TabBarView.
class AdminHomeScreen extends StatelessWidget {
  const AdminHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: const HomeAppBar(),
        body: SafeArea(
          child: Column(
            children: [
              const TabBar(
                // Scrollable so the labels fit a phone.
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  Tab(text: 'Verifications'),
                  Tab(text: 'Disputes'),
                  Tab(text: 'Reviews'),
                  Tab(text: 'Stats'),
                  Tab(text: 'Users'),
                ],
              ),
              const Expanded(
                child: TabBarView(
                  children: [
                    VerificationQueueScreen(),
                    DisputeQueueScreen(),
                    ModerationQueueScreen(),
                    PlatformStatsScreen(),
                    ManageUsersScreen(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
