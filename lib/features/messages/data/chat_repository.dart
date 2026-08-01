import 'package:cloud_firestore/cloud_firestore.dart';

import '../../jobs/domain/job.dart';
import '../domain/conversation.dart';
import '../domain/message.dart';

/// Reads and writes chat conversations and messages. UI/controllers depend on
/// this interface so tests can use a fake without Firestore.
abstract interface class ChatRepository {
  /// Finds or lazily creates the conversation between [job]'s requestor and
  /// its accepted provider, returning its id. The job must already have an
  /// accepted provider.
  Future<String> openConversation(Job job);

  /// Streams the user's conversations, most recently active first.
  Stream<List<Conversation>> watchConversations(String uid);

  /// Streams one conversation — null until it has been created.
  Stream<Conversation?> watchConversation(String conversationId);

  /// Streams the newest 50 messages, newest first (the thread renders them
  /// with a reversed list, so the newest sits at the bottom).
  Stream<List<Message>> watchMessages(String conversationId);

  /// Appends a text message and updates the conversation's preview fields and
  /// the recipient's unread counter.
  Future<void> sendMessage({
    required Conversation conversation,
    required String senderId,
    required String text,
  });

  /// Zeroes the user's unread counter on a conversation (called when they
  /// open the thread).
  Future<void> markRead(String conversationId, String uid);

  /// Streams the user's total unread-message count across all conversations,
  /// for the Messages tab badge.
  Stream<int> watchTotalUnread(String uid);
}

/// Firestore-backed [ChatRepository]. Conversations live at
/// `conversations/{jobId}_{providerId}` with their messages in a
/// subcollection. Counter updates use dotted-path atomic increments in the
/// same batch as the message write — not a transaction, since the unread
/// counter is a UI hint, not an invariant-critical value.
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
    // Only start a fresh thread while the job is live. Once it has ended, an
    // existing thread is still reachable (read-only after its grace window),
    // but we don't spin up a brand-new, ungated conversation on a closed job.
    if (!existing.exists && job.status == JobStatus.inProgress) {
      // The winning bid carries the provider's photo snapshot (see
      // bid.dart's providerPhotoUrl); reuse it here rather than a second
      // profile lookup.
      final winningBid =
          await _job(job.id).collection('bids').doc(providerId).get();
      // Both sides may race to create the same doc; they write identical
      // initial content, so last-write-wins is harmless. `lastMessageAt` is
      // set at creation so the empty thread still sorts into the list.
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

  /// Normalises Firestore Timestamps to DateTime before building the model.
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
