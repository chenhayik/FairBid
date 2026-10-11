import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../../core/location/region.dart';
import '../../../core/location/region_picker_screen.dart';
import '../../../core/util/service_categories.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/form_widgets.dart';
import '../../../core/widgets/location_field.dart';
import '../../../core/widgets/user_avatar.dart';
import '../../auth/domain/user_role.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../auth/presentation/validators.dart';
import '../../onboarding/data/document_storage_repository.dart';

/// Comma-separated skills -> trimmed, de-duplicated list (empties dropped).
List<String> _parseSkills(String text) => {
      for (final s in text.split(','))
        if (s.trim().isNotEmpty) s.trim(),
    }.toList();

/// What:   Edit Profile form: name, phone, map location, About and (providers) category and skills.
/// Input:  [AuthController.user]; email is read-only.
/// Output: One Save calls [AuthController.updateProfile] and pops.
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _skills;
  late final TextEditingController _bio;
  String? _category;
  String? _locationLabel;
  PickedLocation? _picked;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthController>().user;
    _name = TextEditingController(text: user?.displayName ?? '');
    _phone = TextEditingController(text: user?.phone ?? '');
    _skills = TextEditingController(text: user?.skills.join(', ') ?? '');
    _bio = TextEditingController(text: user?.bio ?? '');
    _locationLabel = user?.location;
    // The dropdown asserts its value is one of the items.
    _category = kServiceCategories.contains(user?.category)
        ? user!.category
        : null;
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _skills.dispose();
    _bio.dispose();
    super.dispose();
  }

  /// Opens the Penang map picker; the pick is saved with the Save button.
  Future<void> _pickLocation() async {
    final user = context.read<AuthController>().user;
    final isProvider = user?.role == UserRole.provider;
    final lat = isProvider ? user?.baseLat : user?.defaultLat;
    final lng = isProvider ? user?.baseLng : user?.defaultLng;
    final code = isProvider ? user?.baseDistrictCode : user?.defaultDistrictCode;
    final picked = await RegionPickerScreen.show(
      context,
      initialCenter: lat == null || lng == null ? null : LatLng(lat, lng),
      initialRegion: Region.fromMap({
        'districtCode': code,
        'town': isProvider ? user?.baseTown : user?.defaultTown,
      }),
    );
    if (picked == null) return;
    setState(() {
      _picked = picked;
      _locationLabel = picked.address;
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final isProvider =
        context.read<AuthController>().user?.role == UserRole.provider;
    try {
      await context.read<AuthController>().updateProfile(
            displayName: _name.text,
            phone: _phone.text,
            location: _locationLabel,
            bio: _bio.text,
            picked: _picked,
            category: isProvider ? _category : null,
            skills: isProvider ? _parseSkills(_skills.text) : null,
          );
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save your profile')));
      return;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthController>().user;
    return Scaffold(
      appBar: AppBar(title: const Text('Edit Profile')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              _AvatarPicker(photoUrl: user?.profilePhotoUrl),
              AppTextField(
                controller: _name,
                label: 'Full Name',
                textInputAction: TextInputAction.next,
                validator: (v) => Validators.required(v, 'Full name'),
              ),
              if (user?.email != null)
                _ReadOnlyField(label: 'Email Address', value: user!.email!),
              AppTextField(
                controller: _phone,
                label: 'Phone Number',
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
              ),
              Text('Location', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 6),
              LocationField(
                label: _locationLabel,
                placeholder: 'Pick your location in Penang',
                onTap: _pickLocation,
              ),
              const SizedBox(height: 16),
              AppTextField(
                controller: _bio,
                label: 'About',
                hint: 'Tell clients about your experience and skills.',
                maxLines: 5,
                maxLength: 500,
              ),
              if (user?.role == UserRole.provider) ...[
                Text('Your services',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                Text('Primary Service Category',
                    style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  initialValue: _category,
                  hint: const Text('Select a category...'),
                  items: [
                    for (final category in kServiceCategories)
                      DropdownMenuItem(value: category, child: Text(category)),
                  ],
                  onChanged: (value) => setState(() => _category = value),
                ),
                const SizedBox(height: 16),
                AppTextField(
                  controller: _skills,
                  label: 'Skills',
                  hint: 'E.g. Pipe repair, Water heater, Aircon servicing',
                  helperText: 'Separate skills with commas.',
                ),
              ],
              const SizedBox(height: 8),
              PrimaryButton(
                label: 'Save',
                busy: _saving,
                onPressed: _saving ? null : _save,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Avatar with a "Change photo" / "Add photo" action; picking uploads and saves the URL at once, not on Save.
class _AvatarPicker extends StatefulWidget {
  const _AvatarPicker({required this.photoUrl});

  final String? photoUrl;

  @override
  State<_AvatarPicker> createState() => _AvatarPickerState();
}

class _AvatarPickerState extends State<_AvatarPicker> {
  final _picker = ImagePicker();
  bool _uploading = false;

  Future<void> _pick() async {
    // Captured before the first await to avoid using context across the gap.
    final auth = context.read<AuthController>();
    final storage = context.read<DocumentStorageRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final uid = auth.user?.uid;
    if (uid == null || _uploading) return;

    final XFile? file;
    try {
      file = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        imageQuality: 85,
      );
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Could not open the photo picker.')));
      return;
    }
    if (file == null) return; // cancelled

    setState(() => _uploading = true);
    try {
      final url = await storage.uploadAvatar(uid: uid, file: file);
      await auth.updateProfilePhoto(url);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Could not upload your photo. Please try again.')));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasPhoto = widget.photoUrl != null && widget.photoUrl!.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Center(
        child: Column(
          children: [
            SizedBox(
              width: 80,
              height: 80,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  UserAvatar(
                      photoUrl: widget.photoUrl, radius: 40, iconSize: 40),
                  if (_uploading)
                    const CircularProgressIndicator(strokeWidth: 2),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _uploading ? null : _pick,
              child: Text(hasPhoto ? 'Change photo' : 'Add photo'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A non-editable field styled like [AppTextField] (e.g. the email).
class _ReadOnlyField extends StatelessWidget {
  const _ReadOnlyField({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Text(value,
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}
