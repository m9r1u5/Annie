import 'dart:convert';

import 'package:flutter/services.dart';

/// Talks to the Android Auto car screen (CarService.kt).
class CarBridge {
  static const _channel = MethodChannel('saferoute/car');

  /// Called when the car screen asks for something (e.g. "end" the trip).
  static void Function(String action)? onAction;

  static void init() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'carAction') onAction?.call('${call.arguments}');
      return null;
    });
  }

  static Future<void> send(Map<String, dynamic> state) async {
    try {
      await _channel.invokeMethod('update', jsonEncode(state));
    } catch (_) {}
  }
}
