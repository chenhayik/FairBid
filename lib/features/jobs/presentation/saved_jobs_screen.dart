import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/keyed_stream_builder.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/job_repository.dart';
import '../domain/job.dart';
import 'widgets/job_card.dart';

/// The signed-in user's bookmarked jobs - fed by the bookmark toggle on
/// [JobCard] across the feed and "Jobs near you".
class SavedJobsScreen extends StatelessWidget {
  const SavedJobsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthController>().user;
    final watchlist = user?.watchlist ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('Saved jobs')),
      body: SafeArea(
        child: KeyedStreamBuilder<List<Job>>(
          // The watchlist really does change here (bookmarking from this very
          // screen), so key on its contents: re-create the query when the ids
          // change, and only then.
          cacheKey: watchlist.join(','),
          create: () =>
              context.read<JobRepository>().watchSavedJobs(watchlist),
          builder: (context, snapshot) {
            if (!snapshot.hasData && !snapshot.hasError) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return const EmptyState(
                icon: Icons.error_outline,
                title: 'Could not load saved jobs',
                message: 'Please check your connection and try again.',
              );
            }
            final jobs = snapshot.data ?? [];
            if (jobs.isEmpty) {
              return const EmptyState(
                icon: Icons.bookmark_border,
                title: 'No saved jobs yet',
                message: 'Tap the bookmark on a job to save it here.',
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(24),
              itemCount: jobs.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, i) {
                final job = jobs[i];
                return JobCard(
                  job: job,
                  onTap: () => context.push('/jobs/${job.id}'),
                  saved: true,
                  onToggleSave: () =>
                      context.read<AuthController>().toggleSaved(job.id),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
