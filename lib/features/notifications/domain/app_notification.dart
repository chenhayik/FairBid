import 'package:flutter/material.dart';

/// What a notification is about; picks its list icon.
enum NotificationType {
  bidReceived,
  bidAccepted,
  message,
  verification,
  milestone,
  dispute,
  payment,
  review,
  cancellation,
  appointment;

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
        NotificationType.appointment => Icons.event_outlined,
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
        'appointment' => NotificationType.appointment,
        _ => NotificationType.message,
      };
}

/// What:   One entry in `users/{uid}/notifications`.
/// Input:  Doc data via AppNotification.fromMap (notification_repository.dart); written by `notify()` in functions.
/// Output: Read-only model; the client only flips `read`.
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

  /// In-app deep link (e.g. `/jobs/abc123`); null for none.
  final String? route;
  final bool read;
  final DateTime? createdAt;

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
