import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/util/time_ago.dart';
import '../../../core/widgets/app_widgets.dart';
import '../../../core/widgets/face_crop.dart';
import '../../onboarding/domain/id_extract.dart';
import '../data/verification_repository.dart';
import '../domain/pending_verification.dart';
import 'widgets/document_gallery.dart';

/// The review screen an admin opens from the queue. Shows the applicant's
/// profile and uploaded documents, then records an Approve / Reject decision.
class VerificationDetailScreen extends StatefulWidget {
  const VerificationDetailScreen({super.key, required this.verification});

  final PendingVerification verification;

  @override
  State<VerificationDetailScreen> createState() =>
      _VerificationDetailScreenState();
}

class _VerificationDetailScreenState extends State<VerificationDetailScreen> {
  bool _busy = false;
  late final Future<List<VerificationDocument>> _identityDocs;
  late final Future<IdExtract?> _idExtract;

  PendingVerification get v => widget.verification;

  @override
  void initState() {
    super.initState();
    // The sensitive ID/selfie photos live in the applicant's private doc.
    _identityDocs =
        context.read<VerificationRepository>().loadIdentityDocuments(v.uid);
    _idExtract = context.read<VerificationRepository>().loadIdExtract(v.uid);
  }

  Future<void> _approve() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Approve verification?'),
        content: Text(
            '${v.displayName} will be granted verified marketplace access'
            '${v.isProvider ? ' and can start bidding on jobs' : ''}.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _decide(approved: true);
    }
  }

  Future<void> _reject() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => const _RejectReasonDialog(),
    );
    // Null → the admin cancelled; a string (possibly empty) → proceed.
    if (reason != null) {
      await _decide(approved: false, reason: reason);
    }
  }

  Future<void> _decide({required bool approved, String? reason}) async {
    // Capture the messenger before the async gap and the pop, so the snackbar
    // shows on the queue (this screen's context is gone once we pop).
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await context
          .read<VerificationRepository>()
          .decide(uid: v.uid, approved: approved, reason: reason);
      if (!mounted) return;
      context.pop();
      messenger.showSnackBar(SnackBar(
        content: Text(approved
            ? '${v.displayName} approved.'
            : '${v.displayName} rejected.'),
      ));
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(const SnackBar(
          content: Text('Could not save the decision. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
          title: Text('Verify ${v.isProvider ? 'Provider' : 'Requestor'}')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  _ApplicantHeader(item: v),
                  const SizedBox(height: 24),
                  Text('Applicant Details', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 12),
                  _DetailsCard(item: v),
                  const SizedBox(height: 24),
                  FutureBuilder<List<VerificationDocument>>(
                    future: _identityDocs,
                    builder: (context, snap) {
                      final loading =
                          snap.connectionState == ConnectionState.waiting;
                      // Identity photos first (the ones that matter most),
                      // then the public certificates/portfolio.
                      final all = [
                        ...?snap.data,
                        ...v.documents,
                      ];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _FaceComparisonCard(documents: snap.data ?? const []),
                          Row(
                            children: [
                              Expanded(
                                child: Text('Verification Documents',
                                    style: theme.textTheme.titleLarge),
                              ),
                              Text(loading ? '…' : '${all.length}',
                                  style: theme.textTheme.labelLarge?.copyWith(
                                      color:
                                          theme.colorScheme.onSurfaceVariant)),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (loading)
                            const Padding(
                              padding: EdgeInsets.all(24),
                              child: Center(
                                  child: CircularProgressIndicator()),
                            )
                          else
                            DocumentGallery(
                              documents: all,
                              emptyMessage:
                                  'This applicant submitted without uploading '
                                  'any documents. Reject and ask them to '
                                  'resubmit if verification is required.',
                            ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 24),
                  Text('Automated ID checks', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 12),
                  FutureBuilder<IdExtract?>(
                    future: _idExtract,
                    builder: (context, snap) => _IdChecksCard(
                      extract: snap.data,
                      loading: snap.connectionState == ConnectionState.waiting,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const InfoBanner(
                    icon: Icons.gpp_good_outlined,
                    title: 'Before you decide',
                    body:
                        'Confirm the identity document is legible and matches '
                        'the applicant\'s name. Approving grants trusted access '
                        'to the marketplace.',
                  ),
                ],
              ),
            ),
            _DecisionBar(busy: _busy, onApprove: _approve, onReject: _reject),
          ],
        ),
      ),
    );
  }
}

/// The face on the ID next to the face in the selfie, for a quick visual
/// match. Hidden unless both photos are present.
class _FaceComparisonCard extends StatelessWidget {
  const _FaceComparisonCard({required this.documents});

  final List<VerificationDocument> documents;

  VerificationDocument? _find(String label) =>
      documents.where((d) => d.label == label).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final id = _find(VerificationDocument.idLabel);
    final selfie = _find(VerificationDocument.selfieLabel);
    if (id == null || selfie == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    Widget face(String label, VerificationDocument d, double size) => Column(
          children: [
            FaceCrop(url: d.url, box: d.faceBox, size: size),
            const SizedBox(height: 6),
            Text(label, style: theme.textTheme.labelLarge),
          ],
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Face comparison', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('Compare the two faces before approving.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            // Each crop takes half the card's width, so it fits any phone.
            LayoutBuilder(builder: (context, constraints) {
              const gap = 12.0;
              final size = (constraints.maxWidth - gap) / 2;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  face('On ID', id, size),
                  const SizedBox(width: gap),
                  face('Selfie', selfie, size),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }
}

/// The server's advisory MyKad check. The admin still decides.
class _IdChecksCard extends StatelessWidget {
  const _IdChecksCard({required this.extract, required this.loading});

  final IdExtract? extract;
  final bool loading;

  static String _tri(bool? v, String yes, String no) =>
      v == null ? 'Unknown' : (v ? yes : no);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = extract;
    if (e == null) {
      return AppCard(
        child: Text(loading ? 'Loading…' : 'No automated check yet',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    final (label, color) = switch (e.verdict) {
      IdVerdict.passed => ('Passed', context.fairbid.successText),
      IdVerdict.needsReview => ('Needs review', context.fairbid.warningText),
      IdVerdict.rejected => ('Rejected', context.fairbid.danger),
    };
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PillBadge(label: label, color: color),
          const SizedBox(height: 12),
          _KeyValue(label: 'IC number', value: e.maskedIc ?? 'Not read'),
          const SizedBox(height: 8),
          _KeyValue(label: 'Age', value: _tri(e.ageOk, '18 or older', 'Under 18')),
          const SizedBox(height: 8),
          _KeyValue(
              label: 'Name',
              value: _tri(e.nameMatches, 'Matches account', 'Does not match')),
          const SizedBox(height: 8),
          _KeyValue(
              label: 'Gender',
              value: _tri(e.genderConsistent, 'Consistent', 'Inconsistent')),
          for (final f in e.failures) ...[
            const SizedBox(height: 8),
            Text('• ${idFailureLabel(f)}', style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// Sticky bottom action bar with the two decision buttons.
class _DecisionBar extends StatelessWidget {
  const _DecisionBar({
    required this.busy,
    required this.onApprove,
    required this.onReject,
  });

  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final danger = context.fairbid.danger;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: context.fairbid.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: busy ? null : onReject,
              style: OutlinedButton.styleFrom(
                foregroundColor: danger,
                side: BorderSide(color: danger),
              ),
              icon: const Icon(Icons.close_rounded, size: 18),
              label: const Text('Reject'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PrimaryButton(
              label: 'Approve',
              busy: busy,
              trailingIcon: Icons.check_rounded,
              onPressed: onApprove,
            ),
          ),
        ],
      ),
    );
  }
}

/// Avatar, name, role pill and submission metadata.
class _ApplicantHeader extends StatelessWidget {
  const _ApplicantHeader({required this.item});

  final PendingVerification item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: context.fairbid.subtleBlue,
                child: Icon(
                  item.isProvider
                      ? Icons.handyman_outlined
                      : Icons.person_outline,
                  size: 28,
                  color: context.fairbid.verified,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.displayName,
                        style: theme.textTheme.titleLarge),
                    const SizedBox(height: 4),
                    PillBadge(
                      label: item.roleSummary,
                      color: item.isProvider
                          ? context.fairbid.verified
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _MetaRow(
            icon: Icons.badge_outlined,
            label: 'Applicant ID',
            value: 'ID-${item.uid.substring(0, item.uid.length.clamp(0, 8))}'
                .toUpperCase(),
          ),
          if (item.email != null)
            _MetaRow(
                icon: Icons.email_outlined,
                label: 'Email',
                value: item.email!),
          _MetaRow(
            icon: Icons.schedule,
            label: 'Submitted',
            value: item.submittedAt == null
                ? 'Unknown'
                : timeAgo(item.submittedAt),
          ),
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow(
      {required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text('$label: ',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          Expanded(
            child: Text(value,
                textAlign: TextAlign.end,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

/// Profile fields captured during onboarding, rendered as labelled rows.
class _DetailsCard extends StatelessWidget {
  const _DetailsCard({required this.item});

  final PendingVerification item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <(String, String)>[
      if (item.phone != null && item.phone!.isNotEmpty)
        ('Phone', item.phone!),
      if (item.location != null && item.location!.isNotEmpty)
        ('Location', item.location!),
      if (item.category != null && item.category!.isNotEmpty)
        ('Service', item.category!),
      if (item.coverageArea != null && item.coverageArea!.isNotEmpty)
        ('Coverage', item.coverageArea!),
      if (item.companyName != null && item.companyName!.isNotEmpty)
        ('Company', item.companyName!),
      if (item.ssmNumber != null && item.ssmNumber!.isNotEmpty)
        ('SSM No.', item.ssmNumber!),
    ];

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (rows.isEmpty && item.skills.isEmpty && (item.bio ?? '').isEmpty)
            Text('No additional profile details were provided.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _KeyValue(label: rows[i].$1, value: rows[i].$2),
          ],
          if (item.skills.isNotEmpty) ...[
            if (rows.isNotEmpty) const SizedBox(height: 16),
            Text('SKILLS', style: theme.textTheme.labelMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final skill in item.skills)
                  PillBadge(label: skill, color: context.fairbid.verified),
              ],
            ),
          ],
          if ((item.bio ?? '').isNotEmpty) ...[
            if (rows.isNotEmpty || item.skills.isNotEmpty)
              const SizedBox(height: 16),
            Text('ABOUT', style: theme.textTheme.labelMedium),
            const SizedBox(height: 4),
            Text(item.bio!, style: theme.textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}

class _KeyValue extends StatelessWidget {
  const _KeyValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(label,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        Expanded(
          child: Text(value,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w500)),
        ),
      ],
    );
  }
}

/// Reject dialog with an optional reason. Returns the reason string on confirm
/// (empty allowed) or null on cancel.
class _RejectReasonDialog extends StatefulWidget {
  const _RejectReasonDialog();

  @override
  State<_RejectReasonDialog> createState() => _RejectReasonDialogState();
}

class _RejectReasonDialogState extends State<_RejectReasonDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final danger = context.fairbid.danger;
    return AlertDialog(
      title: const Text('Reject verification?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Add a reason (shared with the applicant). Optional.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            maxLines: 3,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'e.g. Identity document is blurry, please resubmit.',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: danger),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Reject'),
        ),
      ],
    );
  }
}
