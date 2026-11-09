import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../config.dart';

class AppUpdate {
  final String version;
  final int build;
  final String apkUrl;
  const AppUpdate(this.version, this.build, this.apkUrl);
}

/// Checks the GitHub releases of this repo for a newer APK.
class UpdateService {
  Future<String> currentVersion() async {
    final info = await PackageInfo.fromPlatform();
    return '${info.version} (build ${info.buildNumber})';
  }

  /// Returns the newer release, or null if the app is up to date.
  Future<AppUpdate?> check() async {
    final info = await PackageInfo.fromPlatform();
    final current = int.tryParse(info.buildNumber) ?? 0;
    final res = await http.get(Uri.parse(AppConfig.releasesApi), headers: {
      'Accept': 'application/vnd.github+json',
      'User-Agent': AppConfig.userAgent,
    }).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw Exception('Could not check for updates (HTTP ${res.statusCode}).');
    }
    for (final rRaw in jsonDecode(res.body) as List) {
      final r = rRaw as Map<String, dynamic>;
      final tag = r['tag_name'] as String? ?? '';
      if (!tag.startsWith('v')) continue; // skip the maps release
      final build = int.tryParse(tag.split('.').last) ?? 0;
      final apk = (r['assets'] as List).cast<Map<String, dynamic>>().where(
          (a) => (a['name'] as String).endsWith('.apk'));
      if (apk.isEmpty) continue;
      if (build > current) {
        return AppUpdate(tag, build, apk.first['browser_download_url'] as String);
      }
      return null; // newest app release is not newer
    }
    return null;
  }
}
