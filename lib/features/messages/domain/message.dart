/// What:   A single text chat message.
/// Input:  `conversations/{conversationId}/messages/{messageId}` via Message.fromMap (chat_repository.dart).
/// Output: Immutable model.
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

  factory Message.fromMap(String id, Map<String, dynamic> m) => Message(
        id: id,
        senderId: m['senderId'] as String? ?? '',
        text: m['text'] as String? ?? '',
        createdAt: m['createdAt'] as DateTime?,
      );
}
