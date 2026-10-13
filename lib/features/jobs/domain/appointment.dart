/// What:   The agreed visit time on an in-progress job.
/// Input:  Job doc field `appointment` via JobRepository.watchJob() (job_repository.dart).
/// Output: startAt, plus endAt for multi-day work.
class Appointment {
  const Appointment({required this.startAt, this.endAt});

  final DateTime startAt;
  final DateTime? endAt;

  /// What:   Parser for the job's `appointment` map.
  /// Input:  Map from JobRepository (Timestamps already converted to DateTime).
  /// Output: Appointment, or null when the map is absent.
  static Appointment? fromMap(Map<String, dynamic>? m) {
    final startAt = m?['startAt'] as DateTime?;
    if (startAt == null) return null;
    return Appointment(startAt: startAt, endAt: m!['endAt'] as DateTime?);
  }
}

/// What:   A pending proposal of 1-3 visit times.
/// Input:  Job doc field `appointmentProposal` via JobRepository.watchJob() (job_repository.dart).
/// Output: The options, proposer uid, and optional finish date and note.
class AppointmentProposal {
  const AppointmentProposal({
    required this.options,
    required this.by,
    this.endAt,
    this.note,
  });

  final List<DateTime> options;

  /// The uid of the party who proposed.
  final String by;
  final DateTime? endAt;
  final String? note;

  /// What:   Parser for the job's `appointmentProposal` map.
  /// Input:  Map from JobRepository (Timestamps already converted to DateTime).
  /// Output: AppointmentProposal, or null when the map is absent.
  static AppointmentProposal? fromMap(Map<String, dynamic>? m) {
    final by = m?['by'] as String?;
    final options = (m?['options'] as List?)?.whereType<DateTime>().toList();
    if (by == null || options == null || options.isEmpty) return null;
    return AppointmentProposal(
      options: options,
      by: by,
      endAt: m!['endAt'] as DateTime?,
      note: m['note'] as String?,
    );
  }
}
