import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/location/address_hint.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../auth/presentation/auth_controller.dart';
import '../../data/job_repository.dart';
import '../../domain/job.dart';
import '../../domain/service_address.dart';
import 'service_address_sheet.dart';

/// What:   Card for the job's private [ServiceAddress].
/// Input:  Address via JobRepository.watchJobAddress() (job_repository.dart); [isOwner].
/// Output: Owner edits it via ServiceAddressSheet; the accepted provider gets a read-only view.
class JobAddressCard extends StatefulWidget {
  const JobAddressCard({super.key, required this.job, required this.isOwner});

  final Job job;
  final bool isOwner;

  @override
  State<JobAddressCard> createState() => _JobAddressCardState();
}

class _JobAddressCardState extends State<JobAddressCard> {
  // Cached so a parent rebuild doesn't resubscribe.
  late final Stream<ServiceAddress?> _address =
      context.read<JobRepository>().watchJobAddress(widget.job.id);

  /// The pin's reverse geocode, cached; the stored JobLocation has no street detail.
  Future<AddressHint?>? _hint;

  /// What:   Reverse geocode of the job pin, cached.
  /// Output: AddressHint via reverseGeocode() (address_hint.dart), or null for a pin at 0,0.
  /// Notes:  Starts early so "Add address" opens pre-filled.
  Future<AddressHint?> _addressHint() {
    final location = widget.job.location;
    if (location.lat == 0 && location.lng == 0) return Future.value();
    return _hint ??= reverseGeocode(LatLng(location.lat, location.lng));
  }

  /// What:   Opens the address sheet and saves the result.
  /// Input:  [initial] saved address, if any; the pin hint is used only when none exists.
  /// Output: JobRepository.setJobAddress(); a snackbar if the save fails.
  Future<void> _editAddress(BuildContext context, ServiceAddress? initial) async {
    final defaultTown = context.read<AuthController>().user?.defaultTown;
    // A saved address always beats the geocoder's guess.
    final hint = initial == null ? await _addressHint() : null;
    if (!context.mounted) return;
    final result = await ServiceAddressSheet.show(
      context,
      initial: initial,
      defaultCity: widget.job.location.town ?? defaultTown,
      hint: hint,
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
        // Idempotent (`??=`), so safe across rebuilds.
        if (widget.isOwner && address == null && !snapshot.hasError) {
          _addressHint();
        }
        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Address', style: theme.textTheme.titleLarge),
              const SizedBox(height: 12),
              // A failed read must not look like "not set yet".
              if (snapshot.hasError)
                Text(
                  "Couldn't load the address. Check your connection, then "
                  'reopen this job.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                )
              else if (widget.isOwner)
                _OwnerContent(
                    job: widget.job, address: address, onEdit: _editAddress)
              else
                _ProviderContent(job: widget.job, address: address),
            ],
          ),
        );
      },
    );
  }
}

/// What:   Owner view of the address.
/// Input:  [address] from JobRepository.watchJobAddress(); [onEdit] opens the sheet.
/// Output: The address with Edit, or an Add button.
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

/// What:   The provider's read-only address, with turn-by-turn buttons.
/// Input:  [address] from JobRepository.watchJobAddress(); [job] for the map pin.
/// Output: Address text, plus Google Maps and Waze buttons that open the app.
/// How:    Navigates to the address text, else to the pin; none if neither exists.
class _ProviderContent extends StatelessWidget {
  const _ProviderContent({required this.job, required this.address});
  final Job job;
  final ServiceAddress? address;

  /// What:   Opens a map link in the external app.
  /// Output: Launches [uri]; a snackbar if it can't open.
  Future<void> _open(BuildContext context, Uri uri) async {
    final messenger = ScaffoldMessenger.of(context);
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!opened) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Could not open the map app. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pin = job.location;
    final hasPin = pin.lat != 0 || pin.lng != 0;
    final destination = address != null
        ? address!.formatted.replaceAll('\n', ', ')
        : '${pin.lat},${pin.lng}';
    final waze = address != null ? {'q': destination} : {'ll': destination};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (address == null)
          Text(
            "The requestor hasn't shared the address yet.",
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          )
        else ...[
          Text(address!.formatted, style: theme.textTheme.bodyMedium),
          if (address!.accessNote != null &&
              address!.accessNote!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Access notes', style: theme.textTheme.labelMedium),
            Text(address!.accessNote!,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ],
        if (address != null || hasPin) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => _open(
                    context,
                    Uri.https('www.google.com', '/maps/dir/',
                        {'api': '1', 'destination': destination})),
                icon: const Icon(Icons.directions_outlined, size: 18),
                label: const Text('Google Maps'),
              ),
              OutlinedButton.icon(
                onPressed: () => _open(
                    context,
                    Uri.https(
                        'waze.com', '/ul', {...waze, 'navigate': 'yes'})),
                icon: const Icon(Icons.navigation_outlined, size: 18),
                label: const Text('Waze'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
