import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';

class hiBOBBackgroundService {
  static Future<void> initialize() async {
    try {
      final service = FlutterBackgroundService();

      await service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: onStart,
          autoStart: false,
          isForegroundMode: true,
          notificationChannelId: 'hibob_foreground',
          initialNotificationTitle: 'hiBOB activo',
          initialNotificationContent: 'Te estoy acompañando en segundo plano',
          foregroundServiceTypes: [
            AndroidForegroundType.microphone,
            AndroidForegroundType.mediaProjection,
          ],
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: onStart,
          onBackground: (_) => true,
        ),
      );
    } catch (e) {
      debugPrint('[BackgroundService] Failed to initialize: $e');
    }
  }

  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();

    if (service is AndroidServiceInstance) {
      service.on('setAsForeground').listen((event) {
        service.setAsForegroundService();
      });

      service.on('setAsBackground').listen((event) {
        service.setAsBackgroundService();
      });
    }

    service.on('stopService').listen((event) {
      service.stopSelf();
    });

    // Mantener el servicio vivo
    Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (service is AndroidServiceInstance) {
        if (await service.isForegroundService()) {
          service.setForegroundNotificationInfo(
            title: "hiBOB te escucha",
            content: "Dime qué necesitas configurar",
          );
        }
      }
    });
  }
}
