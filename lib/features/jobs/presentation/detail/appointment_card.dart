import 'package:add_2_calendar/add_2_calendar.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/util/visit_time.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../../data/job_repository.dart';
import '../../domain/appointment.dart';
import '../../domain/job.dart';
import 'propose_time_sheet.dart';

/// What:   Card for agreeing and showing a job's visit time.
/// Input:  Job via JobRepository.watchJob() (job_repository.dart); [isOwner] from the viewer's role.
/// Output: Propose, confirm, withdraw or reschedule buttons that call JobRepository,
///         and Add to calendar once confirmed.
///         On the visit day the provider also gets On my way / I've arrived.
/// How:    Shows the agreed time, then any pending proposal; a lone proposed time is preselected.
class AppointmentCard extends StatefulWidget {
  const AppointmentCard({super.key, required this.job, required this.isOwner});

  final Job job;

  final bool isOwner;

  @override
  State<AppointmentCard> createState() => AppointmentCardState();
}

/// What:   State of [AppointmentCard]; public so the screen can reach it through a GlobalKey.
class AppointmentCardState extends State<AppointmentCard> {
  int? _selected;
  bool _busy = false;

  Job get _job => widget.job;
  String get _myUid =>
      (widget.isOwner ? _job.requestorId : _job.acceptedProviderId) ?? '';
  String get _otherName => widget.isOwner
      ? _job.acceptedProviderName ?? 'the provider'
      : _job.requestorName;

  @override
  void initState() {
    super.initState();
    _selected = _onlyOption(_job.appointmentProposal);
  }

  @override
  void didUpdateWidget(AppointmentCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = oldWidget.job.appointmentProposal?.options;
    final after = _job.appointmentProposal?.options;
    if (!listEquals(before, after)) {
      _selected = _onlyOption(_job.appointmentProposal);
    }
  }

  /// What:   Preselects a lone proposed time.
  /// Output: Index 0 when the proposal has exactly one option, else null.
  int? _onlyOption(AppointmentProposal? proposal) =>
      proposal?.options.length == 1 ? 0 : null;

  /// What:   Confirms the picked time (also called by the bottom bar).
  /// Output: Calls respondToAppointment; with none picked, scrolls here.
  Future<void> confirm() async {
    if (_busy) return;
    final index = _selected;
    if (index == null) {
      await Scrollable.ensureVisible(context);
      return;
    }
    await _run(
      (repo) => repo.respondToAppointment(_job.id, index),
    );
  }

  /// What:   Runs one JobRepository call with busy state.
  /// Input:  [call] such as respondToAppointment or markArrived (job_repository.dart).
  /// Output: Sets [_busy] while it runs; a failure shows the callable's message (or a generic one) in a snackbar.
  Future<void> _run(Future<void> Function(JobRepository repo) call) async {
    setState(() => _busy = true);
    final repo = context.read<JobRepository>();
    final messenger = ScaffoldMessenger.of(context);
    String? error;
    try {
      await call(repo);
    } on FirebaseFunctionsException catch (e) {
      error = e.message ?? 'Something went wrong. Please try again.';
    } catch (_) {
      error = 'Something went wrong. Please try again.';
    }
    if (error != null) messenger.showSnackBar(SnackBar(content: Text(error)));
    if (mounted) setState(() => _busy = false);
  }

  void _openSheet() => ProposeTimeSheet.show(context, _job);

  /// What:   Add-to-calendar action.
  /// Input:  The confirmed [appointment] and this card's job.
  /// Output: Opens the phone's calendar with the visit filled in (end defaults to +2h).
  void _addToCalendar(Appointment appointment) {
    Add2Calendar.addEvent2Cal(Event(
      title: _job.title,
      description: 'FairBid visit',
      location: _job.location.address,
      startDate: appointment.startAt,
      endDate: appointment.endAt ??
          appointment.startAt.add(const Duration(hours: 2)),
    ));
  }

  /// What:   On my way button handler.
  /// Output: Asks for an ETA (15/30/45/60 min) in a bottom sheet, then calls JobRepository.markOnTheWay().
  Future<void> _onMyWay() async {
    final eta = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How long until you arrive?',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                for (final minutes in const [15, 30, 45, 60])
                  ActionChip(
                    label: Text('$minutes min'),
                    onPressed: () => Navigator.of(context).pop(minutes),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
    if (eta != null) await _run((repo) => repo.markOnTheWay(_job.id, eta));
  }

  @override
  Widget build(BuildContext context) {
    final appointment = _job.appointment;
    final proposal = _job.appointmentProposal;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (appointment != null) ..._confirmed(context, appointment),
          if (appointment != null && proposal != null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Divider(height: 1),
            ),
          if (proposal != null)
            ..._pending(context, proposal)
          else if (appointment == null)
            ..._none(context),
        ],
      ),
    );
  }

  /// What:   Empty state when no time is agreed or proposed.
  /// Output: Explanation and a Propose a time button.
  List<Widget> _none(BuildContext context) {
    final theme = Theme.of(context);
    return [
      Text('Agree a visit time', style: theme.textTheme.titleMedium),
      const SizedBox(height: 4),
      Text(
        'Pick a time that suits you both. The job can be marked as '
        'delivered once a time is agreed.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 12),
      PrimaryButton(label: 'Propose a time', onPressed: _openSheet),
    ];
  }

  /// What:   The agreed visit.
  /// Output: Start time, optional finish date, visit-day status, Add to calendar and Reschedule.
  List<Widget> _confirmed(BuildContext context, Appointment appointment) {
    final theme = Theme.of(context);
    final endAt = appointment.endAt;
    return [
      Text('Visit confirmed', style: theme.textTheme.titleMedium),
      const SizedBox(height: 4),
      Row(
        children: [
          Icon(
            Icons.event_available_outlined,
            size: 20,
            color: context.fairbid.successText,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              formatVisitTime(appointment.startAt),
              style: theme.textTheme.titleLarge,
            ),
          ),
        ],
      ),
      if (endAt != null) ...[
        const SizedBox(height: 4),
        Text(
          'Finishes on ${formatVisitDate(endAt)}',
          style: theme.textTheme.bodyMedium,
        ),
      ],
      ..._visitDay(context, appointment),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => _addToCalendar(appointment),
          icon: const Icon(Icons.edit_calendar_outlined, size: 18),
          label: const Text('Add to calendar'),
        ),
      ),
      const SizedBox(height: 4),
      SecondaryButton(label: 'Reschedule', onPressed: _busy ? null : _openSheet),
    ];
  }

  /// What:   Visit-day status and the provider's arrival buttons.
  /// Input:  [appointment]; the job's onTheWayAt, arrivedAt and etaMinutes.
  /// Output: Status line, plus On my way / I've arrived for the provider from 3 hours before the visit until arrival.
  List<Widget> _visitDay(BuildContext context, Appointment appointment) {
    final sent = _job.onTheWayAt;
    final arrived = _job.arrivedAt;
    final status = arrived != null
        ? 'Arrived at ${formatClock(arrived)}'
        : sent == null
            ? null
            : '${widget.isOwner ? '$_otherName is' : "You're"} on the way, '
                'about ${_job.etaMinutes} min (sent ${formatClock(sent)})';
    final inWindow = DateTime.now()
        .isAfter(appointment.startAt.subtract(const Duration(hours: 3)));
    return [
      if (status != null) ...[
        const SizedBox(height: 12),
        Text(status, style: Theme.of(context).textTheme.bodyLarge),
      ],
      if (!widget.isOwner && arrived == null && inWindow) ...[
        const SizedBox(height: 12),
        PrimaryButton(label: 'On my way', onPressed: _busy ? null : _onMyWay),
        const SizedBox(height: 8),
        SecondaryButton(
          label: "I've arrived",
          onPressed:
              _busy ? null : () => _run((repo) => repo.markArrived(_job.id)),
        ),
      ],
    ];
  }

  /// What:   The pending proposal.
  /// Output: Own proposal: times with Withdraw. Other party's: time chips with Confirm and Suggest other times.
  List<Widget> _pending(BuildContext context, AppointmentProposal proposal) {
    final theme = Theme.of(context);
    final subdued = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final mine = proposal.by == _myUid;
    final endAt = proposal.endAt;
    final note = proposal.note;
    return [
      Text(
        mine
            ? 'Waiting for $_otherName to confirm'
            : '$_otherName suggested '
                  '${proposal.options.length == 1 ? 'a time' : 'some times'}',
        style: theme.textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      if (mine)
        for (final option in proposal.options)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(formatVisitTime(option), style: theme.textTheme.bodyLarge),
          )
      else
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (i, option) in proposal.options.indexed)
              ChoiceChip(
                label: Text(formatVisitTime(option)),
                selected: _selected == i,
                onSelected: _busy ? null : (_) => setState(() => _selected = i),
              ),
          ],
        ),
      if (endAt != null) ...[
        const SizedBox(height: 8),
        Text('Finishes on ${formatVisitDate(endAt)}', style: subdued),
      ],
      if (note != null && note.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('"$note"', style: subdued),
      ],
      const SizedBox(height: 12),
      if (mine)
        SecondaryButton(
          label: 'Withdraw',
          onPressed: _busy
              ? null
              : () => _run((repo) => repo.withdrawAppointmentProposal(_job.id)),
        )
      else ...[
        PrimaryButton(
          label: 'Confirm',
          busy: _busy,
          onPressed: _selected == null ? null : confirm,
        ),
        const SizedBox(height: 8),
        SecondaryButton(
          label: 'Suggest other times',
          onPressed: _busy ? null : _openSheet,
        ),
      ],
    ];
  }
}
