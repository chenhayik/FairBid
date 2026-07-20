import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Wires FCM push into the app: permission, the Android channel, foreground
/// display, and tap → deep-link routing. Token *storage* is the
/// NotificationRepository's job; this service only surfaces the moments
/// (init, token refresh) the caller should react to.
abstract interface class PushService {
  /// One-time setup: creates the notification channel, hooks foreground
  /// messages and tap handlers. [onOpenRoute] receives the in-app route of a
  /// tapped notification (from background, foreground banner, or cold start).
  /// [onTokenRefresh] fires when FCM rotates this device's token.
  Future<void> init({
    required void Function(String route) onOpenRoute,
    required void Function() onTokenRefresh,
  });

  /// Asks the user for notification permission (Android 13+ shows a system
  /// prompt). Safe to call repeatedly — the OS only prompts once.
  Future<void> requestPermission();
}

/// Production [PushService] over `firebase_messaging` +
/// `flutter_local_notifications`.
class FirebasePushService implements PushService {
  FirebasePushService({FirebaseMessaging? messaging})
      : _messaging = messaging ?? FirebaseMessaging.instance;

  final FirebaseMessaging _messaging;
  final _local = FlutterLocalNotificationsPlugin();

  /// Must match the manifest's default-channel meta-data AND the
  /// `channelId` the onNotificationCreated Cloud Function sends.
  static const _channel = AndroidNotificationChannel(
    'fairbid_default',
    'FairBid notifications',
    description: 'Bids, messages, payments and job updates.',
    importance: Importance.high,
  );

  @override
  Future<void> init({
    required void Function(String route) onOpenRoute,
    required void Function() onTokenRefresh,
  }) async {
    // Local-notifications setup, used to display foreground messages (FCM
    // shows nothing on its own while the app is open).
    await _local.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (response) {
        final route = response.payload;
        if (route != null && route.isNotEmpty) onOpenRoute(route);
      },
    );
    await _local
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);

    // Foreground: render the push as a local notification banner.
    FirebaseMessaging.onMessage.listen((message) {
      final notification = message.notification;
      if (notification == null) return;
      _local.show(
        notification.hashCode,
        notification.title,
        notification.body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channel.id,
            _channel.name,
            channelDescription: _channel.description,
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        payload: message.data['route'] as String?,
      );
    });

    // Background → tapped: the app resumes on the notification's route.
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      final route = message.data['route'] as String?;
      if (route != null && route.isNotEmpty) onOpenRoute(route);
    });

    // Terminated → tapped: the app cold-starts from the notification.
    final initial = await _messaging.getInitialMessage();
    final initialRoute = initial?.data['route'] as String?;
    if (initialRoute != null && initialRoute.isNotEmpty) {
      onOpenRoute(initialRoute);
    }

    _messaging.onTokenRefresh.listen((_) => onTokenRefresh());
  }

  @override
  Future<void> requestPermission() async {
    await _messaging.requestPermission();
  }
}
