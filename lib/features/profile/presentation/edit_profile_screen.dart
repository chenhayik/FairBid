import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/form_widgets.dart';
import '../../../core/widgets/user_avatar.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../auth/presentation/validators.dart';
import '../../onboarding/data/document_storage_repository.dart';

/// Pushed form for editing the signed-in user's profile: full name, phone,
/// location and About text. Email is shown read-only. One Save writes through
/// [AuthController.updateProfile] and pops back to the profile.
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _location;
  late final TextEditingController _bio;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthController>().user;
    _name = TextEditingController(text: user?.displayName ?? '');
    _phone = TextEditingController(text: user?.phone ?? '');
    _location = TextEditingController(text: user?.location ?? '');
    _bio = TextEditingController(text: user?.bio ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _location.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    await context.read<AuthController>().updateProfile(
          displayName: _name.text,
          phone: _phone.text,
          location: _location.text,
          bio: _bio.text,
        );
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
              AppTextField(
                controller: _location,
                label: 'Location',
                textInputAction: TextInputAction.next,
              ),
              AppTextField(
                controller: _bio,
                label: 'About',
                hint: 'Tell clients about your experience and skills.',
                maxLines: 5,
                maxLength: 500,
              ),
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

/// The profile-photo control at the top of the form: the current avatar (or
/// the placeholder, via [UserAvatar]) with a "Change photo" / "Add photo"
/// action beneath it. Picking a photo uploads it immediately and saves the
/// resulting URL, rather than waiting for the form's own Save button -
/// mirroring how the other upload boxes in the app behave.
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
    // Capture everything context-derived before the first await, so nothing
    // below ever touches BuildContext across an async gap.
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

/// A non-editable field styled like [AppTextField] for values the user can view
/// but not change here (e.g. their email address).
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
