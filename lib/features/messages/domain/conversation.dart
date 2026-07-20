/// A chat thread between a job's requestor and its accepted provider, stored
/// at `conversations/{jobId}_{providerId}`. The deterministic id means either
/// side opening the chat lazily creates (or finds) the same document — no
/// duplicate threads for one job. Framework-agnostic; the repository handles
/// the Firestore ↔ [Conversation] mapping.
class Conversation {
  const Conversation({
    required this.id,
    required this.jobId,
    required this.jobTitle,
    required this.requestorId,
    required this.requestorName,
    required this.providerId,
    required this.providerName,
    this.lastMessageText = '',
    this.lastMessageSenderId,
    this.lastMessageAt,
    this.unreadCounts = const {},
    this.chatClosesAt,
  });

  final String id;
  final String jobId;

  /// Denormalised so the conversation list renders without loading each job.
  final String jobTitle;

  final String requestorId;
  final String requestorName;
  final String providerId;
  final String providerName;

  /// Preview of the newest message, denormalised onto the conversation so the
  /// list renders without reading any message documents.
  final String lastMessageText;
  final String? lastMessageSenderId;
  final DateTime? lastMessageAt;

  /// Per-participant unread counters, keyed by uid. Incremented for the
  /// recipient on every send; zeroed when they open the thread.
  final Map<String, int> unreadCounts;

  /// When the thread stops accepting new messages. Set by a Cloud Function to
  /// 14 days after the job ends (completed/cancelled), and cleared back to null
  /// while a dispute is open or a milestone is in rework. Null means the chat
  /// is open. History stays readable forever regardless.
  final DateTime? chatClosesAt;

  /// Whether the composer should be enabled: open while [chatClosesAt] is unset
  /// or still in the future.
  bool isOpenAt(DateTime now) =>
      chatClosesAt == null || now.isBefore(chatClosesAt!);

  /// Both participants' uids — mirrors the stored `participantIds` array that
  /// backs the "my conversations" query.
  List<String> get participantIds => [requestorId, providerId];

  /// The counterparty's display name from [uid]'s point of view.
  String otherPartyName(String uid) =>
      uid == providerId ? requestorName : providerName;

  /// [uid]'s unread-message count on this thread.
  int unreadFor(String uid) => unreadCounts[uid] ?? 0;

  /// Immutable identity fields written at creation. The preview fields,
  /// counters and timestamps are maintained by the repository.
  Map<String, dynamic> toMap() => {
        'jobId': jobId,
        'jobTitle': jobTitle,
        'requestorId': requestorId,
        'requestorName': requestorName,
        'providerId': providerId,
        'providerName': providerName,
        'participantIds': participantIds,
      };

  /// Builds a [Conversation] from a document id and its (already
  /// Timestamp-normalised) data map.
  factory Conversation.fromMap(String id, Map<String, dynamic> m) =>
      Conversation(
        id: id,
        jobId: m['jobId'] as String? ?? '',
        jobTitle: m['jobTitle'] as String? ?? '',
        requestorId: m['requestorId'] as String? ?? '',
        requestorName: m['requestorName'] as String? ?? 'Requestor',
        providerId: m['providerId'] as String? ?? '',
        providerName: m['providerName'] as String? ?? 'Provider',
        lastMessageText: m['lastMessageText'] as String? ?? '',
        lastMessageSenderId: m['lastMessageSenderId'] as String?,
        lastMessageAt: m['lastMessageAt'] as DateTime?,
        unreadCounts: {
          for (final e in ((m['unreadCount'] as Map?) ?? const {}).entries)
            e.key as String: (e.value as num?)?.toInt() ?? 0,
        },
        chatClosesAt: m['chatClosesAt'] as DateTime?,
      );
}
