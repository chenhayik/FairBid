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

/// What:   Admin review screen for one applicant.
/// Input:  [verification] from the queue; identity photos and the ID check via VerificationRepository.
/// Output: Profile, documents, face comparison and ID checks; Approve / Reject calls decide() then pops.
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
    _identityDocs =
        context.read<VerificationRepository>().loadIdentityDocuments(v.uid);
    _idExtract = context.read<VerificationRepository>().loadIdExtract(v.uid);
  }

  Future<void> _approve() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Approve verification?',
      body: '${v.displayName} will be granted verified marketplace access'
          '${v.isProvider ? ' and can start bidding on jobs' : ''}.',
      actionLabel: 'Approve',
    );
    if (confirmed) {
      await _decide(approved: true);
    }
  }

  Future<void> _reject() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => const _RejectReasonDialog(),
    );
    // Null means cancelled; an empty string is a valid "no reason".
    if (reason != null) {
      await _decide(approved: false, reason: reason);
    }
  }

  Future<void> _decide({required bool approved, String? reason}) async {
    // Captured early: this screen's context is gone after the pop, and the snackbar belongs on the queue.
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
                      // Identity photos first, then public certificates and portfolio.
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

/// ID face beside selfie face for a visual match; hidden unless both photos exist.
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
            // Each crop is half the card's width.
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

/// The server's advisory MyKad check; the admin decides.
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
          ..._keyValueRows([
            ('IC number', e.maskedIc ?? 'Not read'),
            ('Age', _tri(e.ageOk, '18 or older', 'Under 18')),
            ('Name', _tri(e.nameMatches, 'Matches account', 'Does not match')),
            ('Gender', _tri(e.genderConsistent, 'Consistent', 'Inconsistent')),
          ], 8),
          for (final f in e.failures) ...[
            const SizedBox(height: 8),
            Text('• ${idFailureLabel(f)}', style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// Sticky bottom bar with Reject and Approve.
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

/// Avatar, name, role pill and submission details.
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

/// Onboarding profile fields as labelled rows.
class _DetailsCard extends StatelessWidget {
  const _DetailsCard({required this.item});

  final PendingVerification item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <(String, String)>[
      for (final (label, value) in [
        ('Phone', item.phone),
        ('Location', item.location),
        ('Service', item.category),
        ('Coverage', item.coverageArea),
        ('Company', item.companyName),
        ('SSM No.', item.ssmNumber),
      ])
        if (value != null && value.isNotEmpty) (label, value),
    ];

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (rows.isEmpty && item.skills.isEmpty && (item.bio ?? '').isEmpty)
            Text('No additional profile details were provided.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ..._keyValueRows(rows, 12),
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

/// [rows] as `_KeyValue`s separated by [gap].
List<Widget> _keyValueRows(List<(String, String)> rows, double gap) => [
      for (final (i, (label, value)) in rows.indexed) ...[
        if (i > 0) SizedBox(height: gap),
        _KeyValue(label: label, value: value),
      ],
    ];

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

/// Reject dialog with an optional reason; pops the text on confirm, null on cancel.
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
