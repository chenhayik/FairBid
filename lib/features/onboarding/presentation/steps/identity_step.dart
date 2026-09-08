import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/ssm_number.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/form_widgets.dart';
import '../../../../core/widgets/image_source_sheet.dart';
import '../../../auth/presentation/validators.dart';
import '../../domain/onboarding_data.dart';
import '../../domain/ssm_extract.dart';
import '../onboarding_controller.dart';

/// Stage 3 - "Verify your identity": ID and selfie uploads, plus - for a
/// registered business - the SSM registration number and its document.
class IdentityStep extends StatefulWidget {
  const IdentityStep({super.key});

  @override
  State<IdentityStep> createState() => _IdentityStepState();
}

class _IdentityStepState extends State<IdentityStep> {
  late final TextEditingController _businessName;
  late final TextEditingController _ssmNumber;

  @override
  void initState() {
    super.initState();
    final data = context.read<OnboardingController>().data;
    _businessName = TextEditingController(text: data.businessName)
      ..addListener(_writeThrough);
    _ssmNumber = TextEditingController(text: data.ssmNumber)
      ..addListener(_writeThrough);
  }

  @override
  void dispose() {
    _businessName.dispose();
    _ssmNumber.dispose();
    super.dispose();
  }

  /// Mirrors both fields into the controller on every keystroke, so the
  /// Continue gate always reflects what is on screen and nothing is lost when
  /// the stage rebuilds.
  void _writeThrough() {
    final onboarding = context.read<OnboardingController>();
    onboarding.data.businessName = _businessName.text.trim();
    onboarding.setSsmNumber(_ssmNumber.text);
    setState(() {});
  }

  /// Lets the user pick camera or gallery, then runs [upload] with the choice.
  Future<void> _chooseAndUpload(
    BuildContext context,
    String title,
    Future<void> Function(ImageSource) upload,
  ) async {
    final source = await showImageSourceSheet(context, title: title);
    if (source != null) await upload(source);
  }

  /// Copies the server's proposals into the fields. Only ever reached through
  /// the explicit "Use these details" button.
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

    // Everything still standing between the applicant and Continue, phrased
    // for display. Deriving the button's state FROM this list - rather than
    // computing the two separately - is what stops the hint ever disagreeing
    // with the button.
    //
    // The server's verdict is deliberately not in here: being held up by a
    // failed automated check on a genuine document is worse than letting an
    // admin look at it, which is what the review queue is for.
    final missing = <String>[
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
        Text('Front of ID (MyKad or Passport)',
            style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        UploadBox(
          onTap: () => _chooseAndUpload(
              context, 'Add your ID', onboarding.pickIdDocument),
          icon: Icons.badge_outlined,
          hint: 'Take a photo or choose one\nJPEG, PNG up to 10MB',
          pickedName: data.idDocumentUrl == null ? null : 'Document uploaded',
        ),
        const SizedBox(height: 16),
        Text('Selfie holding your ID', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        UploadBox(
          onTap: () =>
              _chooseAndUpload(context, 'Add your selfie', onboarding.pickSelfie),
          icon: Icons.portrait_outlined,
          hint: 'Take a photo or choose one\nMake sure face and ID are clear',
          pickedName: data.selfieUrl == null ? null : 'Photo uploaded',
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
          // The fields come BEFORE the upload deliberately. The extract trigger
          // fires the moment the bytes land and cross-checks the document
          // against the number already on record, so the natural order has to
          // put the number in first for that check to have anything to compare.
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
          // Three states, not two. The upload box covers "sending"; this
          // covers the gap between the bytes landing and the server reporting
          // back, which is otherwise blank - and on a re-upload would show the
          // previous card vanishing, reading as a failure rather than progress.
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
          // Optional, and deliberately so. A Certificate proves the business
          // exists; only the Profile ties it to a person. Requiring it would
          // mean every provider buying a document that carries their NRIC,
          // date of birth and home address - excessive for verifying a trade.
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

/// Shown while the document is up but the server has not reported back yet.
/// Says explicitly that the wait is not blocking, because it is not: the
/// Continue gate never waits on the verdict.
class _CheckingCard extends StatelessWidget {
  const _CheckingCard({required this.timedOut});

  /// Set once the wait has run long enough that a spinner would be a lie -
  /// a cold-started or crashed function must not leave one turning forever.
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
                  : 'Checking your document - you can carry on filling in the '
                      'form.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows what the server read out of the uploaded document, and why it is or
/// is not satisfied. Nothing here reaches the profile until the applicant taps
/// "Use these details".
class _ExtractCard extends StatelessWidget {
  const _ExtractCard({
    required this.extract,
    required this.typedNumber,
    required this.onUse,
  });

  final SsmExtract extract;

  /// What the applicant typed, compared here as well as on the server. The
  /// server can only cross-check a number already saved when the upload landed;
  /// this covers the applicant who uploads first and types afterwards.
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
          Row(
            children: [
              Icon(passed ? Icons.check_circle_outline : Icons.info_outline,
                  size: 18,
                  color: passed
                      ? context.fairbid.successText
                      : context.fairbid.warningText),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  passed ? 'Document checks passed' : 'We need a closer look',
                  style: theme.textTheme.labelLarge,
                ),
              ),
            ],
          ),
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
