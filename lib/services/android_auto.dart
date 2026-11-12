import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class ShizukuStatus {
  final bool installed; // Shizuku app on the phone
  final bool running; // Shizuku service started
  final bool granted; // SafeRoute allowed to use it
  final String installer; // who Android thinks installed SafeRoute
  const ShizukuStatus(this.installed, this.running, this.granted, this.installer);

  bool get ready => installed && running && granted;

  /// Android Auto only lists apps it thinks came from the Play Store.
  bool get visibleInAndroidAuto => installer == 'com.android.vending';
}

/// Installs SafeRoute through Shizuku with the Play Store as "installer",
/// which Android Auto needs before it will list the app.
class AndroidAutoHelper {
  static const _ch = MethodChannel('saferoute/shizuku');

  static Future<ShizukuStatus> status() async {
    try {
      final m = Map<String, dynamic>.from(await _ch.invokeMethod('status') as Map);
      return ShizukuStatus(m['installed'] == true, m['running'] == true, m['granted'] == true,
          '${m['installer'] ?? ''}');
    } catch (_) {
      return const ShizukuStatus(false, false, false, '');
    }
  }

  static Future<void> requestPermission() async {
    try {
      await _ch.invokeMethod('request');
    } catch (_) {}
  }

  /// Reinstalls the SafeRoute that's on the phone now. Returns "OK" or an error.
  /// On success Android closes SafeRoute; open it again afterwards.
  static Future<String> reinstallSelf() async =>
      '${await _ch.invokeMethod('installSelf')}';

  /// Downloads an update and installs it through Shizuku. Returns "OK" or an error.
  static Future<String> downloadAndInstall(String url, void Function(double) onProgress) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/saferoute_update.apk');
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(url)));
      if (res.statusCode != 200) return 'Download failed (HTTP ${res.statusCode})';
      final total = res.contentLength ?? 0;
      var done = 0;
      final sink = file.openWrite();
      await for (final chunk in res.stream) {
        sink.add(chunk);
        done += chunk.length;
        if (total > 0) onProgress(done / total);
      }
      await sink.close();
    } finally {
      client.close();
    }
    return '${await _ch.invokeMethod('installFile', {'path': file.path})}';
  }
}
