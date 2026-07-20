/// A single chat message, stored at
/// `conversations/{conversationId}/messages/{messageId}`. Text-only for v1
/// (image messages are deferred). Framework-agnostic; the repository handles
/// the Firestore ↔ [Message] mapping.
class Message {
  const Message({
    required this.id,
    required this.senderId,
    required this.text,
    this.createdAt,
  });

  final String id;
  final String senderId;
  final String text;
  final DateTime? createdAt;

  /// Fields written to Firestore. `createdAt` for a new message is set by the
  /// repository, so it is omitted here.
  Map<String, dynamic> toMap() => {
        'senderId': senderId,
        'text': text,
      };

  /// Builds a [Message] from a document id and its (already
  /// Timestamp-normalised) data map.
  factory Message.fromMap(String id, Map<String, dynamic> m) => Message(
        id: id,
        senderId: m['senderId'] as String? ?? '',
        text: m['text'] as String? ?? '',
        createdAt: m['createdAt'] as DateTime?,
      );
}
