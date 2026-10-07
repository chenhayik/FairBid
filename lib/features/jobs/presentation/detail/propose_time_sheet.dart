import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/visit_time.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../../../core/widgets/form_widgets.dart';
import '../../data/job_repository.dart';
import '../../domain/job.dart';

const _minLead = Duration(minutes: 30);
const _maxAhead = Duration(days: 90);
const _maxOptions = 3;
const _maxNoteLength = 300;

/// What:   Validator for proposed visit times.
/// Input:  Picked [options] (null = empty row), optional [endAt], and [now].
/// Output: An error message, or null when valid.
/// How:    Same rules as the server's validateProposal() (functions/scheduling.js).
String? validateVisitTimes({
  required List<DateTime?> options,
  DateTime? endAt,
  required DateTime now,
}) {
  final times = options.whereType<DateTime>().toList();
  if (times.isEmpty || times.length != options.length) {
    return 'Pick a date and time for each row, or remove the row.';
  }
  if (times.toSet().length != times.length) {
    return 'Each time must be different.';
  }
  if (times.any((t) => t.isBefore(now.add(_minLead)))) {
    return 'Each time must be at least 30 minutes from now.';
  }
  if (times.any((t) => t.isAfter(now.add(_maxAhead)))) {
    return 'Each time must be within the next 90 days.';
  }
  if (endAt != null) {
    final latest = times.reduce((a, b) => a.isAfter(b) ? a : b);
    if (!endAt.isAfter(latest)) {
      return 'The finish date must be on or after the last visit time.';
    }
    if (endAt.isAfter(latest.add(_maxAhead))) {
      return 'The finish date must be within 90 days of the visit.';
    }
  }
  return null;
}

/// What:   Bottom sheet to propose 1-3 visit times, an optional finish date and a note.
/// Input:  [job] from the job detail screen.
/// Output: Calls JobRepository.proposeAppointment(); closes on success.
/// How:    A bundle task also lists the same provider's other in-progress tasks
///         of that bundle (JobRepository.getBundleTasks()); ticked ones share the times.
/// Notes:  Also used to reschedule and to suggest other times.
class ProposeTimeSheet extends StatefulWidget {
  const ProposeTimeSheet({super.key, required this.job});

  final Job job;

  /// What:   Opener for the propose-a-time sheet.
  /// Input:  The in-progress [job] from the job detail screen.
  /// Output: Modal bottom sheet; resolves when it closes.
  static Future<void> show(BuildContext context, Job job) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ProposeTimeSheet(job: job),
    );
  }

  @override
  State<ProposeTimeSheet> createState() => _ProposeTimeSheetState();
}

class _ProposeTimeSheetState extends State<ProposeTimeSheet> {
  final _note = TextEditingController();
  final _options = <DateTime?>[null];
  DateTime? _finishesOn;
  String? _error;
  bool _busy = false;

  /// Other tasks of the bundle that can share these times, and the ticked ids.
  var _siblings = <Job>[];
  final _also = <String>{};

  @override
  void initState() {
    super.initState();
    if (widget.job.isLiveBundleTask) _loadSiblings();
  }

  /// What:   Loader for sibling bundle tasks that can share these times.
  /// Input:  JobRepository.getBundleTasks() (job_repository.dart).
  /// Output: Fills the ticked "Also use these times for" list (max 10).
  Future<void> _loadSiblings() async {
    final job = widget.job;
    final tasks = await context
        .read<JobRepository>()
        .getBundleTasks(job.bundleId!)
        .catchError((_) => <Job>[]);
    if (!mounted) return;
    final siblings = tasks
        .where((t) =>
            t.id != job.id &&
            t.requestorId == job.requestorId &&
            t.acceptedProviderId == job.acceptedProviderId &&
            t.status == JobStatus.inProgress &&
            t.schedulingRequired &&
            !t.hasPendingCancellation)
        .take(10)
        .toList();
    setState(() {
      _siblings = siblings;
      _also.addAll(siblings.map((t) => t.id));
    });
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  /// A finish date counts as the end of that day.
  DateTime? get _endAt {
    final d = _finishesOn;
    return d == null ? null : DateTime(d.year, d.month, d.day, 23, 59);
  }

  /// Whether the confirmed visit is under 24 hours away.
  bool get _isLateChange {
    final start = widget.job.appointment?.startAt;
    return start != null &&
        start.difference(DateTime.now()) < const Duration(hours: 24);
  }

  Future<DateTime?> _pickDateTime(DateTime? current) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = await showDatePicker(
      context: context,
      initialDate: current ?? today.add(const Duration(days: 1)),
      firstDate: today,
      lastDate: today.add(_maxAhead),
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: current != null
          ? TimeOfDay.fromDateTime(current)
          : const TimeOfDay(hour: 9, minute: 0),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> _pickOption(int index) async {
    final picked = await _pickDateTime(_options[index]);
    if (picked != null) setState(() => _options[index] = picked);
  }

  Future<void> _pickFinish() async {
    final latest = _options.whereType<DateTime>().fold<DateTime?>(
          null,
          (a, b) => a == null || b.isAfter(a) ? b : a,
        ) ??
        DateTime.now();
    final first = DateTime(latest.year, latest.month, latest.day);
    final date = await showDatePicker(
      context: context,
      initialDate: _finishesOn ?? first,
      firstDate: first,
      lastDate: first.add(_maxAhead),
    );
    if (date != null) setState(() => _finishesOn = date);
  }

  Future<void> _send() async {
    final problem = validateVisitTimes(
      options: _options,
      endAt: _endAt,
      now: DateTime.now(),
    );
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final repo = context.read<JobRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final note = _note.text.trim();
    try {
      await repo.proposeAppointment(
        widget.job.id,
        options: _options.whereType<DateTime>().toList()..sort(),
        endAt: _endAt,
        note: note.isEmpty ? null : note,
        alsoJobIds: [
          for (final t in _siblings)
            if (_also.contains(t.id)) t.id,
        ],
      );
      navigator.pop();
      messenger.showSnackBar(
        const SnackBar(content: Text('Sent. They will be asked to confirm.')),
      );
    } on FirebaseFunctionsException catch (e) {
      _fail(e.message);
    } catch (_) {
      _fail(null);
    }
  }

  void _fail(String? message) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = message ?? 'Something went wrong. Please try again.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subdued = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.job.appointment == null
                  ? 'Propose visit times'
                  : 'Reschedule the visit',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Pick up to $_maxOptions times that suit you. '
              'The other person confirms one.',
              style: subdued,
            ),
            if (_isLateChange) ...[
              const SizedBox(height: 12),
              InfoBanner(
                icon: Icons.warning_amber_rounded,
                title: 'Short notice',
                body: 'The visit is less than 24 hours away. A late change '
                    'is recorded on this job.',
                color: context.fairbid.warningText,
              ),
            ],
            const SizedBox(height: 16),
            for (final (i, option) in _options.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : () => _pickOption(i),
                        icon: const Icon(Icons.event_outlined, size: 18),
                        label: Text(
                          option == null
                              ? 'Pick date and time'
                              : formatVisitTime(option),
                        ),
                      ),
                    ),
                    if (_options.length > 1)
                      IconButton(
                        tooltip: 'Remove this time',
                        onPressed: _busy
                            ? null
                            : () => setState(() => _options.removeAt(i)),
                        icon: const Icon(Icons.close),
                      ),
                  ],
                ),
              ),
            if (_options.length < _maxOptions)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed:
                      _busy ? null : () => setState(() => _options.add(null)),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add another time'),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _pickFinish,
                    icon: const Icon(Icons.event_repeat_outlined, size: 18),
                    label: Text(
                      _finishesOn == null
                          ? 'Finishes on (optional)'
                          : 'Finishes on ${formatVisitDate(_finishesOn!)}',
                    ),
                  ),
                ),
                if (_finishesOn != null)
                  IconButton(
                    tooltip: 'Clear the finish date',
                    onPressed:
                        _busy ? null : () => setState(() => _finishesOn = null),
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text('For work that takes more than one day.', style: subdued),
            const SizedBox(height: 16),
            AppTextField(
              controller: _note,
              label: 'Note (optional)',
              hint: 'e.g. Please call before you arrive',
              maxLines: 2,
              maxLength: _maxNoteLength,
              enabled: !_busy,
            ),
            if (_siblings.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Also use these times for:', style: theme.textTheme.titleSmall),
              for (final t in _siblings)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(t.title),
                  value: _also.contains(t.id),
                  onChanged: _busy
                      ? null
                      : (on) => setState(
                          () => on! ? _also.add(t.id) : _also.remove(t.id)),
                ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              ErrorBanner(_error!),
            ],
            const SizedBox(height: 16),
            PrimaryButton(
              label: 'Send',
              busy: _busy,
              onPressed: _busy ? null : _send,
            ),
          ],
        ),
      ),
    );
  }
}
