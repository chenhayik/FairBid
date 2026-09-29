import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/config/platform_config.dart';
import '../../../../core/util/money.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/form_widgets.dart';
import '../../../auth/presentation/validators.dart';
import '../../data/milestone_repository.dart';
import '../../domain/job.dart';
import '../../domain/milestone.dart';

/// Bottom sheet where the accepted provider splits the accepted bid into
/// milestones. The amounts must add up to the accepted bid exactly - checked
/// here for fast feedback and re-enforced by the `proposeMilestonePlan` Cloud
/// Function. The plan is written `proposed` and only becomes fundable once the
/// requestor approves it. Passing [existing] pre-fills the rows to amend a plan
/// that hasn't been fully funded yet.
class ProposeMilestonesSheet extends StatefulWidget {
  const ProposeMilestonesSheet({super.key, required this.job, this.existing});

  final Job job;

  /// The current plan when amending, or null when proposing for the first time.
  final List<Milestone>? existing;

  /// Opens the sheet. Resolves `true` once a plan was proposed.
  static Future<bool?> show(BuildContext context,
      {required Job job, List<Milestone>? existing}) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ProposeMilestonesSheet(job: job, existing: existing),
    );
  }

  @override
  State<ProposeMilestonesSheet> createState() => _ProposeMilestonesSheetState();
}

/// One editable milestone row's text controllers.
class _RowControllers {
  final description = TextEditingController();
  final amount = TextEditingController();

  void dispose() {
    description.dispose();
    amount.dispose();
  }
}

class _ProposeMilestonesSheetState extends State<ProposeMilestonesSheet> {
  final _formKey = GlobalKey<FormState>();
  late final List<_RowControllers> _rows;
  bool _busy = false;
  String? _error;

  bool get _isAmend => (widget.existing?.isNotEmpty ?? false);

  @override
  void initState() {
    super.initState();
    final existing = [...?widget.existing]
      ..sort((a, b) => a.order.compareTo(b.order));
    if (existing.isEmpty) {
      _rows = [_RowControllers()];
    } else {
      _rows = [
        for (final m in existing)
          _RowControllers()
            ..description.text = m.description
            ..amount.text = (m.amountSen / 100).toStringAsFixed(2),
      ];
    }
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  int get _totalSen =>
      _rows.fold(0, (total, row) => total + (parseRmToSen(row.amount.text) ?? 0));

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final targetSen = widget.job.acceptedBidAmountSen;
    if (targetSen != null && _totalSen != targetSen) {
      setState(() => _error =
          'Milestone amounts must add up to the accepted bid of '
          '${formatRm(targetSen)} (currently ${formatRm(_totalSen)}).');
      return;
    }
    final repo = context.read<MilestoneRepository>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await repo.proposeMilestones(widget.job.id, [
        for (final (i, row) in _rows.indexed)
          Milestone(
            id: '',
            jobId: widget.job.id,
            providerId: widget.job.acceptedProviderId!,
            description: row.description.text.trim(),
            amountSen: parseRmToSen(row.amount.text)!,
            order: i,
          ),
      ]);
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not propose the plan. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final targetSen = widget.job.acceptedBidAmountSen;

    return Padding(
      // Keep the form above the keyboard.
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_isAmend ? 'Amend plan' : 'Propose milestones',
                  style: theme.textTheme.headlineMedium),
              const SizedBox(height: 4),
              Text(
                _isAmend
                    ? 'Update the plan. Any change needs the client to approve '
                        'it again before the affected milestones can be funded. '
                        'Already-funded milestones can\'t be changed.'
                    : 'Split the job into steps. The client approves the plan, '
                        'then funds each milestone before you start it and '
                        'releases payment as work is approved.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              if (_error != null) ErrorBanner(_error!),
              for (final (i, row) in _rows.indexed) _buildRow(i, row),
              if (_rows.length < PlatformConfig.maxMilestones)
                TextButton.icon(
                  onPressed: () => setState(() => _rows.add(_RowControllers())),
                  icon: const Icon(Icons.add),
                  label: const Text('Add milestone'),
                ),
              const SizedBox(height: 8),
              if (targetSen != null)
                Text(
                  'Total must equal the accepted bid: ${formatRm(targetSen)}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              const SizedBox(height: 12),
              PrimaryButton(
                label: _isAmend ? 'Submit changes' : 'Propose plan',
                busy: _busy,
                onPressed: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRow(int index, _RowControllers row) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 3,
          child: AppTextField(
            controller: row.description,
            label: 'Milestone ${index + 1}',
            hint: 'What will be delivered?',
            validator: (v) => Validators.required(v, 'Description'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: AppTextField(
            controller: row.amount,
            label: 'Amount',
            hint: '0.00',
            prefixText: 'RM ',
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            validator: (v) {
              final sen = parseRmToSen(v);
              if (sen == null || sen <= 0) return 'Invalid';
              return null;
            },
          ),
        ),
        // Keep at least one row; align the remove button with the fields.
        if (_rows.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 28),
            child: IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _rows.removeAt(index).dispose()),
            ),
          ),
      ],
    );
  }
}
