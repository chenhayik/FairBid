import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/keyed_stream_builder.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../auth/presentation/email_verification_banner.dart';
import '../../jobs/data/job_repository.dart';
import '../../jobs/domain/job.dart';
import '../../jobs/presentation/widgets/job_card.dart';
import 'home_app_bar.dart';

/// Requestor Home: greeting, a prominent "Post a job" call to action, and the
/// requestor's active jobs.
class RequestorHomeScreen extends StatelessWidget {
  const RequestorHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = context.watch<AuthController>().user;
    final firstName = (user?.displayName ?? 'there').split(' ').first;
    final repo = context.read<JobRepository>();

    return Scaffold(
      appBar: const HomeAppBar(),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const EmailVerificationBanner(),
            Text('Hello, $firstName', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 4),
            Text("Here's what's happening today.",
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 24),
            PrimaryButton(
              label: '+ Post a job',
              onPressed: () => context.push('/post-job'),
            ),
            const SizedBox(height: 32),
            Text('Active jobs', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            if (user == null)
              const SizedBox.shrink()
            else
              KeyedStreamBuilder<List<Job>>(
                cacheKey: user.uid,
                create: () => repo.watchMyJobs(user.uid),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return const AppCard(
                      child: EmptyState(
                        icon: Icons.error_outline,
                        title: 'Couldn\'t load your jobs',
                        message: 'Please check your connection and try again.',
                      ),
                    );
                  }
                  final jobs = (snapshot.data ?? [])
                      .where((j) => j.status != JobStatus.completed)
                      .toList();
                  if (jobs.isEmpty) {
                    return const AppCard(
                      child: EmptyState(
                        icon: Icons.work_outline,
                        title: 'No active jobs yet',
                        message:
                            'Post a job to start receiving bids from providers.',
                      ),
                    );
                  }
                  return Column(
                    children: [
                      for (final job in jobs.take(5))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: JobCard(
                            job: job,
                            onTap: () => context.push('/jobs/${job.id}'),
                          ),
                        ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
