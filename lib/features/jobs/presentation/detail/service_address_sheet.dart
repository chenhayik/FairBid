import 'package:flutter/material.dart';

import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/form_widgets.dart';
import '../../../auth/presentation/validators.dart';
import '../../domain/service_address.dart';

/// Modal form to add or edit a job's private [ServiceAddress]. Only shared
/// with the job's hired provider — never with other bidders (see
/// `firestore.rules` and `job_address_card.dart`).
class ServiceAddressSheet extends StatelessWidget {
  const ServiceAddressSheet({super.key, this.initial, this.defaultCity});

  final ServiceAddress? initial;
  final String? defaultCity;

  /// Opens the sheet. Resolves to the entered [ServiceAddress] on save, or
  /// `null` on cancel/dismiss.
  static Future<ServiceAddress?> show(
    BuildContext context, {
    ServiceAddress? initial,
    String? defaultCity,
  }) {
    return showModalBottomSheet<ServiceAddress?>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ServiceAddressSheet(
        initial: initial,
        defaultCity: defaultCity,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Keep the form above the keyboard.
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _ServiceAddressForm(initial: initial, defaultCity: defaultCity),
    );
  }
}

class _ServiceAddressForm extends StatefulWidget {
  const _ServiceAddressForm({this.initial, this.defaultCity});
  final ServiceAddress? initial;
  final String? defaultCity;

  @override
  State<_ServiceAddressForm> createState() => _ServiceAddressFormState();
}

class _ServiceAddressFormState extends State<_ServiceAddressForm> {
  final _formKey = GlobalKey<FormState>();
  late final _line1 = TextEditingController(text: widget.initial?.line1);
  late final _line2 = TextEditingController(text: widget.initial?.line2);
  late final _postcode = TextEditingController(text: widget.initial?.postcode);
  late final _city = TextEditingController(
      text: widget.initial?.city ?? widget.defaultCity);
  late final _accessNote =
      TextEditingController(text: widget.initial?.accessNote);

  @override
  void dispose() {
    _line1.dispose();
    _line2.dispose();
    _postcode.dispose();
    _city.dispose();
    _accessNote.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(ServiceAddress(
      line1: _line1.text.trim(),
      line2: _line2.text.trim().isEmpty ? null : _line2.text.trim(),
      postcode: _postcode.text.trim(),
      city: _city.text.trim(),
      accessNote:
          _accessNote.text.trim().isEmpty ? null : _accessNote.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Service address', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline,
                    size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Only shared with your hired provider — never with other '
                    'bidders.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            AppTextField(
              controller: _line1,
              label: 'Address line 1',
              hint: 'e.g. 12, Jalan Mawar 3',
              validator: (v) => Validators.required(v, 'Address line 1'),
            ),
            AppTextField(
              controller: _line2,
              label: 'Address line 2 (optional)',
              hint: 'Building, taman, floor',
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: AppTextField(
                    controller: _postcode,
                    label: 'Postcode',
                    hint: '11900',
                    keyboardType: TextInputType.number,
                    validator: (v) {
                      final text = v?.trim() ?? '';
                      if (text.isEmpty) {
                        return Validators.required(v, 'Postcode');
                      }
                      if (!RegExp(r'^\d{5}$').hasMatch(text)) {
                        return 'Enter a 5-digit postcode.';
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: AppTextField(
                    controller: _city,
                    label: 'Town/City',
                    hint: 'e.g. Bayan Lepas',
                    validator: (v) => Validators.required(v, 'Town/City'),
                  ),
                ),
              ],
            ),
            AppTextField(
              controller: _accessNote,
              label: 'Access notes (optional)',
              maxLines: 3,
              helperText: 'e.g. gate code, where to park, call on arrival',
            ),
            const SizedBox(height: 8),
            PrimaryButton(label: 'Save address', onPressed: _save),
          ],
        ),
      ),
    );
  }
}
