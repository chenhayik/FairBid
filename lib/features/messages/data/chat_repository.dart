  import 'package:cloud_firestore/cloud_firestore.dart';

import '../../jobs/domain/job.dart';
import '../domain/conversation.dart';
import '../domain/message.dart';

/// What:   Chat API for conversations and messages.
/// Input:  Firestore via FirestoreChatRepository; a fake in tests.
/// Output: Conversation and message streams, sends and read marks.
abstract interface class ChatRepository {
  /// Finds or creates the conversation between [job]'s requestor and accepted provider; returns its id.
  Future<String> openConversation(Job job);

  /// The user's conversations, most recently active first.
  Stream<List<Conversation>> watchConversations(String uid);

  /// One conversation; null until created.
  Stream<Conversation?> watchConversation(String conversationId);

  /// The newest 50 messages, newest first.
  Stream<List<Message>> watchMessages(String conversationId);

  /// Appends a message and updates the preview and the recipient's unread counter.
  Future<void> sendMessage({
    required Conversation conversation,
    required String senderId,
    required String text,
  });

  /// Zeroes the user's unread counter.
  Future<void> markRead(String conversationId, String uid);

  /// Total unread messages across conversations (Messages tab badge).
  Stream<int> watchTotalUnread(String uid);
}

/// What:   Firestore-backed [ChatRepository].
/// Input:  `conversations/{jobId}_{providerId}` with a `messages` subcollection.
/// Output: Models; the unread counter is an atomic increment in the message batch (a UI hint, no transaction).
class FirestoreChatRepository implements ChatRepository {
  FirestoreChatRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _conversations =>
      _firestore.collection('conversations');

  CollectionReference<Map<String, dynamic>> _messages(String conversationId) =>
      _conversations.doc(conversationId).collection('messages');

  DocumentReference<Map<String, dynamic>> _job(String jobId) =>
      _firestore.collection('jobs').doc(jobId);

  @override
  Future<String> openConversation(Job job) async {
    final providerId = job.acceptedProviderId;
    if (providerId == null) {
      throw StateError('Job ${job.id} has no accepted provider to chat with.');
    }
    final id = '${job.id}_$providerId';
    final ref = _conversations.doc(id);
    final existing = await ref.get();
    // Only start a thread while the job is live; existing ones stay reachable.
    if (!existing.exists && job.status == JobStatus.inProgress) {
      // The winning bid carries the provider's photo snapshot.
      final winningBid =
          await _job(job.id).collection('bids').doc(providerId).get();
      // Both sides may race; identical content makes last-write-wins harmless.
      // `lastMessageAt` is set so the empty thread still sorts into the list.
      await ref.set({
        'jobId': job.id,
        'jobTitle': job.title,
        'requestorId': job.requestorId,
        'requestorName': job.requestorName,
        if (job.requestorPhotoUrl != null)
          'requestorPhotoUrl': job.requestorPhotoUrl,
        'providerId': providerId,
        'providerName': job.acceptedProviderName ?? 'Provider',
        if (winningBid.data()?['providerPhotoUrl'] != null)
          'providerPhotoUrl': winningBid.data()!['providerPhotoUrl'],
        'participantIds': [job.requestorId, providerId],
        'unreadCount': {job.requestorId: 0, providerId: 0},
        'lastMessageText': '',
        'lastMessageSenderId': null,
        'lastMessageAt': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
    return id;
  }

  @override
  Stream<List<Conversation>> watchConversations(String uid) {
    return _conversations
        .where('participantIds', arrayContains: uid)
        .orderBy('lastMessageAt', descending: true)
        .snapshots()
        .map((snapshot) => [
              for (final doc in snapshot.docs) _conversationFromDoc(doc),
            ]);
  }

  @override
  Stream<Conversation?> watchConversation(String conversationId) {
    return _conversations
        .doc(conversationId)
        .snapshots()
        .map((doc) => doc.exists ? _conversationFromDoc(doc) : null);
  }

  @override
  Stream<List<Message>> watchMessages(String conversationId) {
    return _messages(conversationId)
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots()
        .map((snapshot) => [
              for (final doc in snapshot.docs) _messageFromDoc(doc),
            ]);
  }

  @override
  Future<void> sendMessage({
    required Conversation conversation,
    required String senderId,
    required String text,
  }) {
    final trimmed = text.trim();
    final convRef = _conversations.doc(conversation.id);
    final recipientId = conversation.participantIds
        .firstWhere((id) => id != senderId, orElse: () => '');

    final batch = _firestore.batch();
    batch.set(_messages(conversation.id).doc(), {
      'senderId': senderId,
      'text': trimmed,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.update(convRef, {
      'lastMessageText': trimmed,
      'lastMessageSenderId': senderId,
      'lastMessageAt': FieldValue.serverTimestamp(),
      if (recipientId.isNotEmpty)
        'unreadCount.$recipientId': FieldValue.increment(1),
    });
    return batch.commit();
  }

  @override
  Future<void> markRead(String conversationId, String uid) {
    return _conversations.doc(conversationId).update({'unreadCount.$uid': 0});
  }

  @override
  Stream<int> watchTotalUnread(String uid) {
    return watchConversations(uid).map((conversations) =>
        conversations.fold(0, (total, c) => total + c.unreadFor(uid)));
  }

  Conversation _conversationFromDoc(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.of(doc.data() ?? {});
    data['lastMessageAt'] = (data['lastMessageAt'] as Timestamp?)?.toDate();
    data['chatClosesAt'] = (data['chatClosesAt'] as Timestamp?)?.toDate();
    return Conversation.fromMap(doc.id, data);
  }

  Message _messageFromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.of(doc.data() ?? {});
    data['createdAt'] = (data['createdAt'] as Timestamp?)?.toDate();
    return Message.fromMap(doc.id, data);
  }
}
