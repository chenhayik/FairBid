/// One entry in a job's server-written activity timeline, stored at
/// `jobs/{jobId}/events/{eventId}` (see the `logJobPosted`/`logJobStatusChange`/
/// `logMilestoneStatusChange` Cloud Functions - the client never writes here).
/// Framework-agnostic - the repository handles the Firestore ↔ [JobEvent]
/// mapping (incl. Timestamp conversion).
class JobEvent {
  const JobEvent({
    required this.id,
    required this.type,
    required this.title,
    this.at,
    this.note,
    this.photoUrls = const [],
    this.by,
  });

  /// The document's id (its path, not a stored field).
  final String id;

  /// The event kind, e.g. `posted`, `assigned`, `funded`, `completed` - used
  /// to pick a leading icon in the UI.
  final String type;

  /// Ready-to-display copy, e.g. `Job completed`.
  final String title;

  final DateTime? at;

  /// The requestor's or provider's own note, e.g. the `handover` event's
  /// site handover note. Null on events that don't carry one.
  final String? note;

  /// Photos attached to the event, e.g. the `handover` event's site photos.
  final List<String> photoUrls;

  /// Uid of whoever triggered the event, e.g. the provider who recorded a
  /// `handover`. Null on event types that don't stamp one.
  final String? by;

  /// Builds a [JobEvent] from a doc id and its (already Timestamp-normalised)
  /// data map.
  factory JobEvent.fromMap(String id, Map<String, dynamic> m) => JobEvent(
        id: id,
        type: m['type'] as String? ?? '',
        title: m['title'] as String? ?? '',
        at: m['at'] as DateTime?,
        note: m['note'] as String?,
        photoUrls:
            (m['photoUrls'] as List?)?.whereType<String>().toList() ?? const [],
        by: m['by'] as String?,
      );
}
