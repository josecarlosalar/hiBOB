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
          initialNotificationTitle: 'hiBOB en guardia',
          initialNotificationContent: 'Estoy protegiendo tu navegación',
          foregroundServiceTypes: [
            AndroidForegroundType.microphone,
          ],
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: onStart,
          onBackground: (_) => true,
        ),
      );
    } catch (e) {
      debugPrint('[BackgroundService] Error: $e');
    }
  }

  static Future<void> startForeground() async {
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

    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: "hiBOB Escudo Activo",
        content: "Te escucho en segundo plano",
      );
    }
  }
}
