/// What:   A chat thread between a job's requestor and accepted provider.
/// Input:  `conversations/{jobId}_{providerId}` via Conversation.fromMap (chat_repository.dart).
/// Output: Immutable model; the deterministic id means either side finds the same thread.
class Conversation {
  const Conversation({
    required this.id,
    required this.jobId,
    required this.jobTitle,
    required this.requestorId,
    required this.requestorName,
    this.requestorPhotoUrl,
    required this.providerId,
    required this.providerName,
    this.providerPhotoUrl,
    this.lastMessageText = '',
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

  /// Each party's photo at creation time, denormalised like the names; null if none.
  final String? requestorPhotoUrl;
  final String providerId;
  final String providerName;
  final String? providerPhotoUrl;

  /// Preview of the newest message, so the list reads no message docs.
  final String lastMessageText;
  final DateTime? lastMessageAt;

  /// Unread counters by uid; +1 for the recipient on send, zeroed on open.
  final Map<String, int> unreadCounts;

  /// When the thread stops accepting messages: 14 days after the job ends (set by a Cloud Function),
  /// null while open or a dispute is open. History stays readable.
  final DateTime? chatClosesAt;

  /// Whether new messages are allowed at [now].
  bool isOpenAt(DateTime now) =>
      chatClosesAt == null || now.isBefore(chatClosesAt!);

  /// Both uids; mirrors the stored `participantIds` used by the list query.
  List<String> get participantIds => [requestorId, providerId];

  /// The counterparty's uid from [uid]'s point of view.
  String otherPartyId(String uid) =>
      uid == providerId ? requestorId : providerId;

  /// The counterparty's display name from [uid]'s point of view.
  String otherPartyName(String uid) =>
      uid == providerId ? requestorName : providerName;

  /// The counterparty's photo URL from [uid]'s point of view, or null.
  String? otherPartyPhotoUrl(String uid) =>
      uid == providerId ? requestorPhotoUrl : providerPhotoUrl;

  /// [uid]'s unread-message count on this thread.
  int unreadFor(String uid) => unreadCounts[uid] ?? 0;

  /// Identity fields written at creation; the repository maintains the rest.
  Map<String, dynamic> toMap() => {
        'jobId': jobId,
        'jobTitle': jobTitle,
        'requestorId': requestorId,
        'requestorName': requestorName,
        if (requestorPhotoUrl != null) 'requestorPhotoUrl': requestorPhotoUrl,
        'providerId': providerId,
        'providerName': providerName,
        if (providerPhotoUrl != null) 'providerPhotoUrl': providerPhotoUrl,
        'participantIds': participantIds,
      };

  factory Conversation.fromMap(String id, Map<String, dynamic> m) =>
      Conversation(
        id: id,
        jobId: m['jobId'] as String? ?? '',
        jobTitle: m['jobTitle'] as String? ?? '',
        requestorId: m['requestorId'] as String? ?? '',
        requestorName: m['requestorName'] as String? ?? 'Requestor',
        requestorPhotoUrl: m['requestorPhotoUrl'] as String?,
        providerId: m['providerId'] as String? ?? '',
        providerName: m['providerName'] as String? ?? 'Provider',
        providerPhotoUrl: m['providerPhotoUrl'] as String?,
        lastMessageText: m['lastMessageText'] as String? ?? '',
        lastMessageAt: m['lastMessageAt'] as DateTime?,
        unreadCounts: {
          for (final e in ((m['unreadCount'] as Map?) ?? const {}).entries)
            e.key as String: (e.value as num?)?.toInt() ?? 0,
        },
        chatClosesAt: m['chatClosesAt'] as DateTime?,
      );
}
