import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import 'settings.dart';

class MapPack {
  final String id;
  final String name;
  final String file;
  final int size;
  final List<double> bbox; // west, south, east, north
  const MapPack(this.id, this.name, this.file, this.size, this.bbox);

  factory MapPack.fromJson(Map<String, dynamic> j) => MapPack(
        j['id'] as String,
        j['name'] as String,
        j['file'] as String,
        (j['size'] as num).toInt(),
        (j['bbox'] as List).map((e) => (e as num).toDouble()).toList(),
      );
}

class MapManifest {
  final String version;
  final List<MapPack> packs;
  final String assetsFile;
  final int assetsSize;
  const MapManifest(this.version, this.packs, this.assetsFile, this.assetsSize);

  factory MapManifest.fromJson(Map<String, dynamic> j) => MapManifest(
        j['version'] as String,
        (j['packs'] as List)
            .map((e) => MapPack.fromJson(e as Map<String, dynamic>))
            .toList(),
        (j['assets'] as Map)['file'] as String,
        ((j['assets'] as Map)['size'] as num).toInt(),
      );
}

class DownloadCancelled implements Exception {}

/// Downloads, updates and deletes offline map packs (one per province).
class MapPackService {
  MapPackService(this.settings);
  final Settings settings;

  MapManifest? manifest;
  final _cancelled = <String>{};

  Future<Directory> _mapsDir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/maps');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Future<String> packPath(String id) async => '${(await _mapsDir()).path}/$id.pmtiles';

  /// Folder holding fonts, sprites and style layers, or null if not downloaded.
  Future<String?> assetsPath() async {
    final v = settings.installedAssetsVersion;
    if (v == null) return null;
    final d = Directory('${(await _mapsDir()).path}/assets_$v');
    return d.existsSync() ? d.path : null;
  }

  /// Paths of province packs that are on the phone.
  Future<Map<String, String>> installedPackPaths() async {
    final out = <String, String>{};
    for (final id in settings.installedPacks.keys) {
      final p = await packPath(id);
      if (File(p).existsSync()) out[id] = p;
    }
    return out;
  }

  Future<MapManifest> fetchManifest() async {
    final res = await http
        .get(Uri.parse('${AppConfig.mapsBaseUrl}/manifest.json'),
            headers: {'User-Agent': AppConfig.userAgent})
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw Exception(
          'Map list not available yet (HTTP ${res.statusCode}). Run the "Build map packs" workflow on GitHub first.');
    }
    manifest = MapManifest.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    return manifest!;
  }

  Future<bool> onWifi() async {
    final r = await Connectivity().checkConnectivity();
    return r.contains(ConnectivityResult.wifi) ||
        r.contains(ConnectivityResult.ethernet);
  }

  /// Null if a big download may start now, otherwise the reason it may not.
  Future<String?> blockedReason() async {
    final r = await Connectivity().checkConnectivity();
    if (r.isEmpty || r.every((e) => e == ConnectivityResult.none)) {
      return 'No internet connection.';
    }
    if (settings.wifiOnly && !await onWifi()) {
      return 'Wi-Fi only is on. Connect to Wi-Fi or allow mobile data in Settings.';
    }
    return null;
  }

  void cancel(String id) => _cancelled.add(id);

  /// Downloads [url] into [target], resuming a partial download if one exists.
  Future<void> _download(String url, File target, String jobId,
      void Function(int done, int total) onProgress) async {
    _cancelled.remove(jobId); // forget any old pause request
    final part = File('${target.path}.part');
    var have = part.existsSync() ? part.lengthSync() : 0;
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url));
      req.headers['User-Agent'] = AppConfig.userAgent;
      if (have > 0) req.headers['Range'] = 'bytes=$have-';
      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode == 200) {
        have = 0; // server ignored the resume request, start over
      } else if (res.statusCode == 416) {
        // Already complete.
        part.renameSync(target.path);
        return;
      } else if (res.statusCode != 206) {
        throw Exception('Download failed (HTTP ${res.statusCode}).');
      }
      final total = have + (res.contentLength ?? 0);
      final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
      var done = have;
      try {
        await for (final chunk in res.stream) {
          if (_cancelled.contains(jobId)) {
            throw DownloadCancelled();
          }
          sink.add(chunk);
          done += chunk.length;
          onProgress(done, total);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      if (target.existsSync()) target.deleteSync();
      part.renameSync(target.path);
    } finally {
      client.close();
      _cancelled.remove(jobId);
    }
  }

  /// Fonts, icons and style layers, shared by all packs.
  Future<void> ensureAssets(MapManifest m, void Function(int, int) onProgress) async {
    if (settings.installedAssetsVersion == m.version && await assetsPath() != null) {
      return;
    }
    final dir = await _mapsDir();
    final zip = File('${dir.path}/${m.assetsFile}');
    await _download('${AppConfig.mapsBaseUrl}/${m.assetsFile}', zip, 'assets', onProgress);
    final out = Directory('${dir.path}/assets_${m.version}');
    if (out.existsSync()) out.deleteSync(recursive: true);
    out.createSync(recursive: true);
    final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
    await extractArchiveToDisk(archive, out.path);
    zip.deleteSync();
    final old = settings.installedAssetsVersion;
    settings.update((s) => s.installedAssetsVersion = m.version);
    if (old != null && old != m.version) {
      final oldDir = Directory('${dir.path}/assets_$old');
      if (oldDir.existsSync()) oldDir.deleteSync(recursive: true);
    }
  }

  Future<void> downloadPack(MapPack pack, void Function(String stage, int done, int total) onProgress) async {
    final m = manifest ?? await fetchManifest();
    await ensureAssets(m, (d, t) => onProgress('Map fonts and icons', d, t));
    final target = File(await packPath(pack.id));
    await _download('${AppConfig.mapsBaseUrl}/${pack.file}', target, pack.id,
        (d, t) => onProgress(pack.name, d, t));
    settings.update((s) => s.installedPacks[pack.id] = m.version);
  }

  Future<void> deletePack(String id) async {
    final f = File(await packPath(id));
    if (f.existsSync()) f.deleteSync();
    final part = File('${f.path}.part');
    if (part.existsSync()) part.deleteSync();
    settings.update((s) => s.installedPacks.remove(id));
  }

  /// Size of a partly downloaded pack, so the list can show "resume".
  Future<int> partialBytes(String id) async {
    final part = File('${await packPath(id)}.part');
    return part.existsSync() ? part.lengthSync() : 0;
  }

  bool updateAvailable(MapPack p) {
    final v = settings.installedPacks[p.id];
    return v != null && manifest != null && v != manifest!.version;
  }

  bool pendingUpdate = false;

  /// Weekly check. Returns a message for the user, or null.
  Future<String?> weeklyCheck({void Function()? onUpdated, bool force = false}) async {
    final last = settings.lastMapCheck;
    if (!force && !pendingUpdate && last != null &&
        DateTime.now().difference(last).inDays < 7) {
      return null;
    }
    if (settings.installedPacks.isEmpty) return null;
    try {
      final m = await fetchManifest();
      settings.update((s) => s.lastMapCheck = DateTime.now());
      final outdated = m.packs.where(updateAvailable).toList();
      if (outdated.isEmpty) {
        pendingUpdate = false;
        return null;
      }
      final blocked = await blockedReason();
      if (blocked != null) {
        pendingUpdate = true;
        return 'Map updates are ready for ${outdated.length} province(s). They will download on Wi-Fi.';
      }
      for (final p in outdated) {
        await downloadPack(p, (_, __, ___) {});
      }
      pendingUpdate = false;
      onUpdated?.call();
      return 'Maps updated to ${m.version}.';
    } catch (_) {
      return null; // Try again next time the app opens.
    }
  }

  /// Runs a pending update when the phone joins Wi-Fi.
  StreamSubscription? watchWifi(Future<void> Function() onWifi) {
    return Connectivity().onConnectivityChanged.listen((r) {
      if (r.contains(ConnectivityResult.wifi)) onWifi();
    });
  }
}
