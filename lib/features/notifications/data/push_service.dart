import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// What:   FCM push wiring: permission, Android channel, foreground display and tap routing.
/// Input:  FirebasePushService over firebase_messaging; a fake in tests.
/// Output: Calls back on tapped routes and token refresh; token storage is NotificationRepository's job.
abstract interface class PushService {
  /// One-time setup. [onOpenRoute] gets the in-app route of a tapped notification
  /// (background, foreground or cold start); [onTokenRefresh] fires when FCM rotates the token.
  Future<void> init({
    required void Function(String route) onOpenRoute,
    required void Function() onTokenRefresh,
  });

  /// Asks for notification permission; safe to repeat (the OS prompts once).
  Future<void> requestPermission();
}

/// What:   Production [PushService] over `firebase_messaging` and `flutter_local_notifications`.
/// Input:  FCM messages and taps.
/// Output: Foreground banners and route callbacks.
class FirebasePushService implements PushService {
  FirebasePushService({FirebaseMessaging? messaging})
      : _messaging = messaging ?? FirebaseMessaging.instance;

  final FirebaseMessaging _messaging;
  final _local = FlutterLocalNotificationsPlugin();

  /// Must match the manifest's default-channel meta-data and the `channelId` sent by `onNotificationCreated`.
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
    // FCM shows nothing in the foreground, so display via local notifications.
    await _local.initialize(
      settings: const InitializationSettings(
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

    FirebaseMessaging.onMessage.listen((message) {
      final notification = message.notification;
      if (notification == null) return;
      _local.show(
        id: notification.hashCode,
        title: notification.title,
        body: notification.body,
        notificationDetails: NotificationDetails(
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

    // Tapped from background.
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      final route = message.data['route'] as String?;
      if (route != null && route.isNotEmpty) onOpenRoute(route);
    });

    // Tapped from terminated.
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
