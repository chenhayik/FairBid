import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/widgets/app_widgets.dart';
import '../../data/job_repository.dart';
import '../../domain/job.dart';
import '../../domain/service_address.dart';
import 'service_address_sheet.dart';

/// Job detail card for the private [ServiceAddress]: editable by the owner,
/// read-only for the accepted provider it's shared with. Text only — the
/// coarse map pin ([JobLocation]) stays on the main detail card, unchanged.
class JobAddressCard extends StatefulWidget {
  const JobAddressCard({super.key, required this.job, required this.isOwner});

  final Job job;
  final bool isOwner;

  @override
  State<JobAddressCard> createState() => _JobAddressCardState();
}

class _JobAddressCardState extends State<JobAddressCard> {
  // Cached so a parent rebuild (e.g. the job detail screen's own
  // StreamBuilder firing on any job-doc change — milestones, cancellation,
  // etc.) doesn't resubscribe to Firestore; job.id is stable for the
  // widget's life, so initState caching is safe.
  late final Stream<ServiceAddress?> _address =
      context.read<JobRepository>().watchJobAddress(widget.job.id);

  Future<void> _editAddress(BuildContext context, ServiceAddress? initial) async {
    final result = await ServiceAddressSheet.show(
      context,
      initial: initial,
      defaultCity: widget.job.location.town,
    );
    if (result == null || !context.mounted) return;
    try {
      await context.read<JobRepository>().setJobAddress(widget.job.id, result);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not save the address. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<ServiceAddress?>(
      stream: _address,
      builder: (context, snapshot) {
        final address = snapshot.data;
        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Address', style: theme.textTheme.titleLarge),
              const SizedBox(height: 12),
              if (widget.isOwner)
                _OwnerContent(
                    job: widget.job, address: address, onEdit: _editAddress)
              else
                _ProviderContent(address: address),
            ],
          ),
        );
      },
    );
  }
}

class _OwnerContent extends StatelessWidget {
  const _OwnerContent({
    required this.job,
    required this.address,
    required this.onEdit,
  });

  final Job job;
  final ServiceAddress? address;
  final Future<void> Function(BuildContext, ServiceAddress?) onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (address != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(address!.formatted, style: theme.textTheme.bodyMedium),
          if (address!.accessNote != null &&
              address!.accessNote!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Access notes', style: theme.textTheme.labelMedium),
            Text(address!.accessNote!,
                style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => onEdit(context, address),
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('Edit'),
            ),
          ),
        ],
      );
    }

    final prominent = job.status == JobStatus.inProgress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          prominent
              ? 'Add the job address so '
                  '${job.acceptedProviderName ?? 'your provider'} can find '
                  'you.'
              : 'Add a service address (only your hired provider will see '
                  'it).',
          style: theme.textTheme.bodyMedium?.copyWith(
              color: prominent ? null : theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        if (prominent)
          PrimaryButton(
              label: 'Add address', onPressed: () => onEdit(context, null))
        else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => onEdit(context, null),
              icon: const Icon(Icons.add_location_alt_outlined, size: 16),
              label: const Text('Add address'),
            ),
          ),
      ],
    );
  }
}

class _ProviderContent extends StatelessWidget {
  const _ProviderContent({required this.address});
  final ServiceAddress? address;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (address == null) {
      return Text(
        "The requestor hasn't shared the address yet.",
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(address!.formatted, style: theme.textTheme.bodyMedium),
        if (address!.accessNote != null && address!.accessNote!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Access notes', style: theme.textTheme.labelMedium),
          Text(address!.accessNote!,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ],
    );
  }
}
