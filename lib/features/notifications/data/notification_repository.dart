import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../domain/app_notification.dart';

/// What:   Notification feed and FCM device-token API.
/// Input:  Firestore and FCM via FirebaseNotificationRepository; a fake in tests.
/// Output: Feed streams; Cloud Functions write notifications, the client only flips `read`.
abstract interface class NotificationRepository {
  /// The user's newest notifications, newest first.
  Stream<List<AppNotification>> watchMine(String uid);

  /// Unread count for the bell badge.
  Stream<int> watchUnreadCount(String uid);

  /// Marks one notification as read.
  Future<void> markRead(String uid, String notificationId);

  /// Marks every unread notification as read.
  Future<void> markAllRead(String uid);

  /// Adds this device's FCM token to the profile's token array; call after sign-in and on refresh.
  Future<void> registerToken(String uid);

  /// Removes this device's token so the next account here gets none of this user's pushes; call before sign-out.
  Future<void> removeToken(String uid);
}

/// What:   Firebase-backed [NotificationRepository].
/// Input:  `users/{uid}/notifications`; tokens in the owner-writable `fcmTokens` array on the user doc.
/// Output: AppNotification streams and token writes.
class FirebaseNotificationRepository implements NotificationRepository {
  FirebaseNotificationRepository({
    FirebaseFirestore? firestore,
    FirebaseMessaging? messaging,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _messaging = messaging ?? FirebaseMessaging.instance;

  final FirebaseFirestore _firestore;
  final FirebaseMessaging _messaging;

  CollectionReference<Map<String, dynamic>> _notifications(String uid) =>
      _firestore.collection('users').doc(uid).collection('notifications');

  @override
  Stream<List<AppNotification>> watchMine(String uid) {
    // Single-field orderBy needs no composite index.
    return _notifications(uid)
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots()
        .map((snapshot) => [
              for (final doc in snapshot.docs) _fromDoc(doc),
            ]);
  }

  @override
  Stream<int> watchUnreadCount(String uid) {
    // Derived from the list's stream.
    return watchMine(uid).map(
        (items) => items.where((n) => !n.read).length);
  }

  @override
  Future<void> markRead(String uid, String notificationId) {
    return _notifications(uid).doc(notificationId).update({'read': true});
  }

  @override
  Future<void> markAllRead(String uid) async {
    final unread =
        await _notifications(uid).where('read', isEqualTo: false).get();
    if (unread.docs.isEmpty) return;
    final batch = _firestore.batch();
    for (final doc in unread.docs) {
      batch.update(doc.reference, {'read': true});
    }
    await batch.commit();
  }

  @override
  Future<void> registerToken(String uid) async {
    final token = await _messaging.getToken();
    if (token == null) return;
    await _firestore.collection('users').doc(uid).update({
      'fcmTokens': FieldValue.arrayUnion([token]),
    });
  }

  @override
  Future<void> removeToken(String uid) async {
    final token = await _messaging.getToken();
    if (token == null) return;
    await _firestore.collection('users').doc(uid).update({
      'fcmTokens': FieldValue.arrayRemove([token]),
    });
  }

  AppNotification _fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.of(doc.data() ?? {});
    data['createdAt'] = (data['createdAt'] as Timestamp?)?.toDate();
    return AppNotification.fromMap(doc.id, data);
  }
}
