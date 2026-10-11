/// What:   One entry in a job's activity timeline (`jobs/{jobId}/events/{eventId}`).
/// Input:  Written by Cloud Functions; read via JobRepository.watchJobEvents().
/// Output: Immutable model; [type] picks the icon.
class JobEvent {
  const JobEvent({
    required this.id,
    required this.type,
    required this.title,
    this.at,
  });

  final String id;

  /// e.g. `posted` or `funded`.
  final String type;

  /// Display text, e.g. `Job completed`.
  final String title;

  final DateTime? at;

  factory JobEvent.fromMap(String id, Map<String, dynamic> m) => JobEvent(
        id: id,
        type: m['type'] as String? ?? '',
        title: m['title'] as String? ?? '',
        at: m['at'] as DateTime?,
      );
}
