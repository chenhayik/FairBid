import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../auth/domain/user_role.dart';
import '../../auth/presentation/auth_controller.dart';
import 'admin_home_screen.dart';
import 'provider_home_screen.dart';
import 'requestor_home_screen.dart';

/// The Home tab. Dispatches to the role-specific dashboard.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final role = context.watch<AuthController>().user?.role;
    return switch (role) {
      UserRole.provider => const ProviderHomeScreen(),
      UserRole.admin => const AdminHomeScreen(),
      _ => const RequestorHomeScreen(),
    };
  }
}
