import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const String _hibobNotificationChannelId = 'hibob_service';
const int _hibobNotificationId = 1088;

final FlutterLocalNotificationsPlugin _localNotifications =
    FlutterLocalNotificationsPlugin();

@pragma('vm:entry-point')
void hiBOBBackgroundServiceOnStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
      service.setForegroundNotificationInfo(
        title: 'hiBOB Activo',
        content: 'Te escucho en segundo plano',
      );
    });

    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
  });
}

@pragma('vm:entry-point')
class hiBOBBackgroundService {
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized) return;
    try {
      // Initialize the notifications plugin first
      await _localNotifications.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );

      const androidChannel = AndroidNotificationChannel(
        _hibobNotificationChannelId,
        'hiBOB Background Service',
        description: 'Mantiene activa la sesion de hiBOB en segundo plano.',
        importance: Importance.low,
      );

      await _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(androidChannel);

      final service = FlutterBackgroundService();

      await service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: hiBOBBackgroundServiceOnStart,
          autoStart: false,
          isForegroundMode: false,
          notificationChannelId: _hibobNotificationChannelId,
          initialNotificationTitle: 'hiBOB en guardia',
          initialNotificationContent: 'Te estoy acompanando',
          foregroundServiceNotificationId: _hibobNotificationId,
          foregroundServiceTypes: [
            AndroidForegroundType.microphone,
          ],
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: hiBOBBackgroundServiceOnStart,
          onBackground: (_) => true,
        ),
      );

      _initialized = true;
    } catch (e) {
      debugPrint('[BackgroundService] Error: $e');
    }
  }

  static Future<void> startForeground() async {
    if (!_initialized) await initialize();
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) {
      await service.startService();
    }
    service.invoke('setAsForeground');
  }

  static Future<void> stop() async {
    final service = FlutterBackgroundService();
    service.invoke('stopService');
  }
}
