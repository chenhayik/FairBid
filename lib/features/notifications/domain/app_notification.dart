import 'package:flutter/material.dart';

/// What a notification is about - drives its leading icon in the list.
enum NotificationType {
  bidReceived,
  bidAccepted,
  message,
  verification,
  milestone,
  dispute,
  payment,
  review,
  cancellation;

  IconData get icon => switch (this) {
        NotificationType.bidReceived => Icons.gavel_rounded,
        NotificationType.bidAccepted => Icons.emoji_events_outlined,
        NotificationType.message => Icons.chat_bubble_outline,
        NotificationType.verification => Icons.verified_user_outlined,
        NotificationType.milestone => Icons.flag_outlined,
        NotificationType.dispute => Icons.balance_outlined,
        NotificationType.payment => Icons.account_balance_wallet_outlined,
        NotificationType.review => Icons.star_outline,
        NotificationType.cancellation => Icons.cancel_outlined,
      };

  static NotificationType fromStorage(String? value) => switch (value) {
        'bid_received' => NotificationType.bidReceived,
        'bid_accepted' => NotificationType.bidAccepted,
        'verification' => NotificationType.verification,
        'milestone' => NotificationType.milestone,
        'dispute' => NotificationType.dispute,
        'payment' => NotificationType.payment,
        'review' => NotificationType.review,
        'cancellation' => NotificationType.cancellation,
        _ => NotificationType.message,
      };
}

/// One entry in `users/{uid}/notifications`. Read-only on the client - the
/// Cloud Functions write them (see `notify()` in functions/index.js), so
/// there is no `toMap()`; the only client-writable field is `read`.
class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    this.route,
    this.read = false,
    this.createdAt,
  });

  final String id;
  final NotificationType type;
  final String title;
  final String body;

  /// In-app deep link (e.g. `/jobs/abc123`), or null for no tap-through.
  final String? route;
  final bool read;
  final DateTime? createdAt;

  /// Builds an [AppNotification] from its doc id and (already
  /// Timestamp-normalised) data map.
  factory AppNotification.fromMap(String id, Map<String, dynamic> m) =>
      AppNotification(
        id: id,
        type: NotificationType.fromStorage(m['type'] as String?),
        title: m['title'] as String? ?? '',
        body: m['body'] as String? ?? '',
        route: m['route'] as String?,
        read: m['read'] as bool? ?? false,
        createdAt: m['createdAt'] as DateTime?,
      );
}
