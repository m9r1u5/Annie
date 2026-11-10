import 'dart:convert';

import 'package:flutter/services.dart';

/// The Valhalla route engine running on the phone (see MainActivity.kt).
/// Takes the same request as the online server and returns the same answer.
class OfflineRouter {
  static const _channel = MethodChannel('saferoute/valhalla');

  /// Plans a route with the tiles in [tilesDir]. Throws on failure.
  static Future<Map<String, dynamic>> route(String tilesDir, Map<String, dynamic> body) async {
    final answer = await _channel
        .invokeMethod<String>('route', {'tilesDir': tilesDir, 'request': jsonEncode(body)})
        .timeout(const Duration(seconds: 15));
    if (answer == null) throw Exception('No answer from the offline route engine');
    return jsonDecode(answer) as Map<String, dynamic>;
  }

  /// Closes the engine so it picks up new or removed tiles.
  static Future<void> reset() async {
    try {
      await _channel.invokeMethod('reset');
    } catch (_) {}
  }
}
