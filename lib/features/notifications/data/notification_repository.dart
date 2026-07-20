import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../domain/app_notification.dart';

/// Reads the user's notification feed and manages their FCM device tokens.
/// Notifications are written only by Cloud Functions; the client streams them
/// and may flip `read`. UI/controllers depend on this interface so tests can
/// use a fake without Firebase.
abstract interface class NotificationRepository {
  /// Streams the user's newest notifications, newest first.
  Stream<List<AppNotification>> watchMine(String uid);

  /// Streams how many of the user's notifications are unread, for the bell
  /// badge.
  Stream<int> watchUnreadCount(String uid);

  /// Marks one notification as read.
  Future<void> markRead(String uid, String notificationId);

  /// Marks every unread notification as read.
  Future<void> markAllRead(String uid);

  /// Registers this device's FCM token on the user's profile (multi-device:
  /// tokens live in an array). Call after sign-in and on token refresh.
  Future<void> registerToken(String uid);

  /// Removes this device's token so the next account on this device can't
  /// receive the previous user's notifications. Call before sign-out.
  Future<void> removeToken(String uid);
}

/// Firebase-backed [NotificationRepository]. Notifications live at
/// `users/{uid}/notifications`; tokens in the `fcmTokens` array on the user
/// doc (owner-writable — the field is not in the protected list).
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
    // Single-field orderBy inside one subcollection — no composite index.
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
    // Derived from the same stream the list uses (like ChatRepository's
    // watchTotalUnread) — one Firestore listener serves both surfaces.
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

  /// Normalises Firestore Timestamps to DateTime before building the model.
  AppNotification _fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.of(doc.data() ?? {});
    data['createdAt'] = (data['createdAt'] as Timestamp?)?.toDate();
    return AppNotification.fromMap(doc.id, data);
  }
}
