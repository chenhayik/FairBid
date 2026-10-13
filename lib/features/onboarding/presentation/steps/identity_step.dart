import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/mykad_number.dart';
import '../../../../core/util/ssm_number.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/form_widgets.dart';
import '../../../../core/widgets/image_source_sheet.dart';
import '../../../auth/presentation/validators.dart';
import '../../domain/id_extract.dart';
import '../../domain/onboarding_data.dart';
import '../../domain/ssm_extract.dart';
import '../onboarding_controller.dart';

/// What:   Provider stage 3: consent, ID and selfie uploads, plus SSM details for businesses.
/// Input:  [OnboardingController] (data, uploads, ID/SSM extracts).
/// Output: Form; Continue is enabled once the "Still needed" list is empty.
class IdentityStep extends StatefulWidget {
  const IdentityStep({super.key});

  @override
  State<IdentityStep> createState() => _IdentityStepState();
}

class _IdentityStepState extends State<IdentityStep> {
  late final TextEditingController _businessName;
  late final TextEditingController _ssmNumber;
  late final TextEditingController _icNumber;

  @override
  void initState() {
    super.initState();
    final data = context.read<OnboardingController>().data;
    _icNumber = TextEditingController(text: data.icNumber)
      ..addListener(_writeThrough);
    _businessName = TextEditingController(text: data.businessName)
      ..addListener(_writeThrough);
    _ssmNumber = TextEditingController(text: data.ssmNumber)
      ..addListener(_writeThrough);
  }

  @override
  void dispose() {
    _businessName.dispose();
    _ssmNumber.dispose();
    _icNumber.dispose();
    super.dispose();
  }

  /// Friendly text for the first issue, shown once 12+ digits are typed.
  static String? _icError(String? value) {
    final text = value ?? '';
    final issues = MyKadNumber.issues(text);
    if (issues.isEmpty || text.replaceAll(RegExp(r'\D'), '').length < 12) {
      return null;
    }
    return switch (issues.first) {
      'wrong-length' => 'A MyKad number has exactly 12 digits.',
      'invalid-date' => 'The birth date in this number is not a real date.',
      'invalid-pb-code' => 'The place-of-birth code in this number is invalid.',
      'underage' => 'You must be 18 or older to offer services.',
      _ => 'Enter a valid MyKad number.',
    };
  }

  /// Mirrors the fields into the controller on every keystroke so Continue matches the screen.
  void _writeThrough() {
    final onboarding = context.read<OnboardingController>();
    onboarding.data.businessName = _businessName.text.trim();
    onboarding.setSsmNumber(_ssmNumber.text);
    onboarding.setIcNumber(_icNumber.text);
    setState(() {});
  }

  /// Asks for camera or gallery, then runs [upload].
  Future<void> _chooseAndUpload(
    BuildContext context,
    String title,
    Future<void> Function(ImageSource) upload,
  ) async {
    final source = await showImageSourceSheet(context, title: title);
    if (source != null) await upload(source);
  }

  /// Copies the server's proposals into the fields ("Use these details").
  void _useExtract() {
    final onboarding = context.read<OnboardingController>()..applySsmExtract();
    _businessName.text = onboarding.data.businessName;
    _ssmNumber.text = onboarding.data.ssmNumber;
  }

  @override
  Widget build(BuildContext context) {
    final onboarding = context.watch<OnboardingController>();
    final theme = Theme.of(context);
    final data = onboarding.data;
    final isBusiness = data.providerType == ProviderType.business;

    // What still blocks Continue; the button derives from it so the hint can't disagree.
    // The server verdict is excluded on purpose: an admin reviews failures.
    final isMyKad = data.idDocumentType == IdDocumentType.mykad;
    final icValid = MyKadNumber.parse(data.icNumber) != null;
    final consented = data.idConsentAt != null;
    final idLocked = (isMyKad && !icValid) || !consented;
    final idBusy = onboarding.isUploading('id_document');
    final selfieBusy = onboarding.isUploading('selfie');
    final busyLabel =
        onboarding.checkingFace ? 'Checking photo…' : 'Uploading…';
    final missing = <String>[
      if (!consented) 'your consent to identity checks',
      if (isMyKad && !icValid) 'a valid MyKad number',
      if (data.idDocumentUrl == null) 'a photo of your ID',
      if (data.selfieUrl == null) 'a selfie holding your ID',
      if (isBusiness) ...[
        if (data.businessName.isEmpty) 'your registered business name',
        if (SsmNumber.parse(data.ssmNumber) == null)
          'a valid SSM registration number',
        if (data.ssmDocumentUrl == null) 'your SSM document',
      ],
    ];
    final canContinue = missing.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Verify your identity', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'To ensure a safe environment for all users, we require a valid '
          'government-issued ID. This is a one-time process to unlock full '
          'bidding capabilities.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        const InfoBanner(
          icon: Icons.verified_user,
          title: 'Unlock "Identity Verified" Badge',
          body: 'Profiles with this badge may receive more responses from '
              'clients. Your details are encrypted and securely stored.',
        ),
        const SizedBox(height: 16),
        if (onboarding.errorMessage != null)
          ErrorBanner(onboarding.errorMessage!),
        Text('Upload Documents', style: theme.textTheme.labelLarge),
        const SizedBox(height: 12),
        // PDPA: face images are sensitive data, so nothing uploads before this.
        CheckboxListTile(
          value: consented,
          onChanged: (v) => onboarding.setIdConsent(v ?? false),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text(
              'I agree to FairBid processing my ID and face photos to verify '
              'my identity. Photos are deleted once our team has reviewed '
              'them; only a masked IC number and the check result are '
              'kept.'),
        ),
        const SizedBox(height: 8),
        SegmentedButton<IdDocumentType>(
          segments: const [
            ButtonSegment(value: IdDocumentType.mykad, label: Text('MyKad')),
            ButtonSegment(
                value: IdDocumentType.passport, label: Text('Passport')),
          ],
          selected: {data.idDocumentType},
          onSelectionChanged: (s) => onboarding.setIdDocumentType(s.first),
        ),
        const SizedBox(height: 16),
        if (isMyKad)
          AppTextField(
            controller: _icNumber,
            label: 'MyKad Number',
            hint: 'e.g. 900101-07-1234',
            prefixIcon: Icons.badge_outlined,
            keyboardType: TextInputType.number,
            helperText: 'Type it before uploading the photo.',
            validator: _icError,
          ),
        Text(isMyKad ? 'Front of MyKad' : 'Passport photo page',
            style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        // Locked until consent is given and the number is valid (the photo is checked against it).
        IgnorePointer(
          ignoring: idLocked,
          child: Opacity(
            // Not greyed while uploading, so the spinner reads as progress.
            opacity: idLocked && !idBusy ? 0.5 : 1,
            child: UploadBox(
              onTap: () => _chooseAndUpload(
                  context, 'Add your ID', onboarding.pickIdDocument),
              busy: idBusy,
              busyLabel: busyLabel,
              icon: Icons.badge_outlined,
              hint: 'Take a photo or choose one\nJPEG, PNG up to 10MB',
              pickedName:
                  data.idDocumentUrl == null ? null : 'Document uploaded',
            ),
          ),
        ),
        // Advisory only; not part of `missing`.
        if (isMyKad && data.idDocumentUrl != null && !idBusy) ...[
          const SizedBox(height: 12),
          if (onboarding.idExtract == null)
            _CheckingCard(
                timedOut: onboarding.idCheckTimedOut,
                message: 'Checking your card - you can carry on filling in '
                    'the form.')
          else
            _IdResultCard(extract: onboarding.idExtract!),
        ],
        const SizedBox(height: 16),
        Text('Selfie holding your ID', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        IgnorePointer(
          ignoring: !consented,
          child: Opacity(
            opacity: consented || selfieBusy ? 1 : 0.5,
            child: UploadBox(
              onTap: () => _chooseAndUpload(
                  context, 'Add your selfie', onboarding.pickSelfie),
              busy: selfieBusy,
              busyLabel: busyLabel,
              icon: Icons.portrait_outlined,
              hint: 'Take a photo or choose one\nMake sure face and ID are clear',
              pickedName: data.selfieUrl == null ? null : 'Photo uploaded',
            ),
          ),
        ),
        if (isBusiness) ...[
          const SizedBox(height: 24),
          Text('Business registration', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Text(
            'Upload the PDF you downloaded from EzBiz or e-Info, not a photo '
            'of a printout. We read the original file to check it is genuine.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          // Fields come before the upload: the server cross-checks the number already on record.
          AppTextField(
            controller: _businessName,
            label: 'Registered Business Name',
            hint: 'e.g. Jin Xiao Long Trading',
            prefixIcon: Icons.business_outlined,
            textInputAction: TextInputAction.next,
            validator: (v) => Validators.required(v, 'Business name'),
          ),
          AppTextField(
            controller: _ssmNumber,
            label: 'SSM Registration Number',
            hint: 'e.g. 201903350205 or 003058656-T',
            prefixIcon: Icons.tag_outlined,
            helperText: 'As printed on your SSM document.',
            validator: SsmNumber.validate,
          ),
          UploadBox(
            onTap: onboarding.pickSsmDocument,
            busy: onboarding.isSsmUploading,
            icon: Icons.description_outlined,
            hint: 'PDF up to 10MB',
            pickedName:
                data.ssmDocumentUrl == null ? null : 'SSM document added',
          ),
          // Covers the gap between the upload landing and the server reporting back.
          if (data.ssmDocumentUrl != null && !onboarding.isSsmUploading) ...[
            const SizedBox(height: 12),
            if (onboarding.ssmExtract == null)
              _CheckingCard(timedOut: onboarding.ssmCheckTimedOut)
            else
              _ExtractCard(
                extract: onboarding.ssmExtract!,
                typedNumber: data.ssmNumber,
                onUse: _useExtract,
              ),
          ],
          // Optional: the Profile carries the owner's NRIC and address, too much to require.
          const SizedBox(height: 20),
          Text('Confirm you are the owner (optional)',
              style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Text(
            'Your certificate proves the business exists, not that it is '
            'yours. Upload your SSM Business Profile and we will check the '
            'registered owner against your name, then delete the file straight '
            'away. It also fills in details for the next steps.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          UploadBox(
            compact: true,
            onTap: onboarding.pickSsmProfile,
            busy: onboarding.isSsmProfileUploading,
            icon: Icons.person_search_outlined,
            hint: 'Optional - PDF up to 10MB',
            pickedName: onboarding.ssmExtract?.ownerNameMatches == true
                ? 'Owner confirmed'
                : null,
          ),
          if (onboarding.ssmExtract?.ownerNameMatches == false) ...[
            const SizedBox(height: 6),
            Text(
              'The owner named on that profile does not match your account '
              'name. Our team will check this by hand.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: context.fairbid.warningText),
            ),
          ],
        ],
        const SizedBox(height: 8),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.lightbulb_outline,
                      size: 18, color: context.fairbid.warningText),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Tips for a successful verification',
                        style: theme.textTheme.labelLarge),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const CheckBullet(
                  'Ensure good lighting without glare or shadows.'),
              const CheckBullet(
                  'All text on the document must be clearly legible.'),
              const CheckBullet(
                  'Do not crop or cut off the edges of the ID.'),
            ],
          ),
        ),
        const SizedBox(height: 24),
        PrimaryButton(
          label: 'Continue',
          trailingIcon: Icons.arrow_forward,
          busy: onboarding.isBusy,
          onPressed:
              canContinue ? () => onboarding.saveAndContinue() : null,
        ),
        if (missing.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Still needed: ${missing.join(', ')}.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

/// Check icon or info icon with a title, for the verdict cards.
Widget _verdictHeader(
    BuildContext context, bool passed, String passedText, String reviewText) {
  return Row(
    children: [
      Icon(passed ? Icons.check_circle_outline : Icons.info_outline,
          size: 18,
          color: passed
              ? context.fairbid.successText
              : context.fairbid.warningText),
      const SizedBox(width: 8),
      Expanded(
        child: Text(passed ? passedText : reviewText,
            style: Theme.of(context).textTheme.labelLarge),
      ),
    ],
  );
}

/// Progress card shown until the server reports; never blocks Continue.
class _CheckingCard extends StatelessWidget {
  const _CheckingCard({
    required this.timedOut,
    this.message = 'Checking your document - you can carry on filling in the '
        'form.',
  });

  final String message;

  /// Swaps the spinner for a message so a stuck function can't spin forever.
  final bool timedOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: Row(
        children: [
          if (timedOut)
            Icon(Icons.schedule_outlined,
                size: 16, color: theme.colorScheme.onSurfaceVariant)
          else
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: context.fairbid.verified),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              timedOut
                  ? 'We will finish checking this in the background. Our team '
                      'reviews it before your account is approved.'
                  : message,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the server read from the SSM document and why it is or isn't satisfied; applied only via [onUse].
class _ExtractCard extends StatelessWidget {
  const _ExtractCard({
    required this.extract,
    required this.typedNumber,
    required this.onUse,
  });

  final SsmExtract extract;

  /// The typed number, compared here too to cover applicants who type after uploading.
  final String typedNumber;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final passed = extract.verdict == SsmVerdict.passed;
    final typed = SsmNumber.parse(typedNumber)?.normalized;
    final read = SsmNumber.parse(extract.registrationNumber ?? '')?.normalized;
    final mismatch = typed != null && read != null && typed != read;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _verdictHeader(
              context, passed, 'Document checks passed', 'We need a closer look'),
          if (extract.hasProposals) ...[
            const SizedBox(height: 8),
            Text('We read:',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            if ((extract.businessName ?? '').isNotEmpty)
              Text(extract.businessName!, style: theme.textTheme.bodyMedium),
            if ((extract.registrationNumber ?? '').isNotEmpty)
              Text(extract.registrationNumber!,
                  style: theme.textTheme.bodyMedium),
            if ((extract.expiryDate ?? '').isNotEmpty)
              Text('Registered until ${extract.expiryDate}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
          if (mismatch) ...[
            const SizedBox(height: 6),
            Text(
              'This does not match the number you entered above.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: context.fairbid.warningText),
            ),
          ],
          for (final reason in extract.reasons) ...[
            const SizedBox(height: 6),
            Text(reason,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
          if (extract.hasProposals) ...[
            const SizedBox(height: 12),
            SecondaryButton(label: 'Use these details', onPressed: onUse),
          ],
        ],
      ),
    );
  }
}

/// Advisory result of the automated MyKad check; an admin decides.
class _IdResultCard extends StatelessWidget {
  const _IdResultCard({required this.extract});

  final IdExtract extract;

  static const _retake = {'ic-mismatch', 'no-ic-found'};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final passed = extract.verdict == IdVerdict.passed;
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _verdictHeader(
              context, passed, 'Card details look good', 'We need a closer look'),
          if (!passed) ...[
            for (final f in extract.failures) ...[
              const SizedBox(height: 6),
              Text(idFailureLabel(f), style: muted),
            ],
            if (extract.failures.any(_retake.contains)) ...[
              const SizedBox(height: 6),
              Text('Try retaking a clear, well-lit photo of the front.',
                  style: muted),
            ],
            const SizedBox(height: 6),
            Text('An admin will review your documents.', style: muted),
          ],
        ],
      ),
    );
  }
}
