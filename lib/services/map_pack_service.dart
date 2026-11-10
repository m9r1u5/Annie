import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import '../utils/geo.dart';
import 'offline_router.dart';
import 'search_service.dart';
import 'settings.dart';

class MapPack {
  final String id;
  final String name;
  final String file;
  final int size;
  final List<double> bbox; // west, south, east, north
  final String? routeFile; // offline routing tiles (zip)
  final int routeSize;
  final String? searchFile; // offline search database
  final int searchSize;
  const MapPack(this.id, this.name, this.file, this.size, this.bbox,
      {this.routeFile, this.routeSize = 0, this.searchFile, this.searchSize = 0});

  factory MapPack.fromJson(Map<String, dynamic> j) => MapPack(
        j['id'] as String,
        j['name'] as String,
        j['file'] as String,
        (j['size'] as num).toInt(),
        (j['bbox'] as List).map((e) => (e as num).toDouble()).toList(),
        routeFile: j['route_file'] as String?,
        routeSize: ((j['route_size'] as num?) ?? 0).toInt(),
        searchFile: j['search_file'] as String?,
        searchSize: ((j['search_size'] as num?) ?? 0).toInt(),
      );

  int get totalSize => size + routeSize + searchSize;

  bool contains(GeoPoint p) =>
      p.lon >= bbox[0] && p.lon <= bbox[2] && p.lat >= bbox[1] && p.lat <= bbox[3];
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

  /// One folder with every province's routing tiles (what the route engine reads).
  Future<String> tilesDir() async {
    final d = Directory('${(await _mapsDir()).path}/valhalla');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d.path;
  }

  /// List of tile files a province added (so deleting it only removes its own).
  Future<File> _routeListFile(String id) async => File('${(await _mapsDir()).path}/route-$id.json');

  Future<String> searchDbPath(String id) async => '${(await _mapsDir()).path}/search-$id.db';

  Future<bool> hasRouting(String id) async => (await _routeListFile(id)).existsSync();

  Future<bool> hasSearch(String id) async => File(await searchDbPath(id)).existsSync();

  /// Search databases on the phone.
  Future<List<String>> installedSearchDbs() async {
    final out = <String>[];
    for (final id in settings.installedPacks.keys) {
      final p = await searchDbPath(id);
      if (File(p).existsSync()) out.add(p);
    }
    return out;
  }

  /// Boxes of the provinces with offline routing on the phone.
  final Map<String, List<double>> routingBoxes = {};

  /// Loads which provinces have routing (call at start-up).
  Future<void> loadRoutingInfo() async {
    routingBoxes.clear();
    for (final id in settings.installedPacks.keys) {
      final f = await _routeListFile(id);
      if (!f.existsSync()) continue;
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        routingBoxes[id] = (j['bbox'] as List).map((e) => (e as num).toDouble()).toList();
      } catch (_) {}
    }
  }

  /// True if offline routing covers this point.
  bool routingCovers(GeoPoint p) => routingBoxes.values.any((b) =>
      p.lon >= b[0] && p.lon <= b[2] && p.lat >= b[1] && p.lat <= b[3]);

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
    final dir = await _mapsDir();

    // 1. The map you see.
    final target = File(await packPath(pack.id));
    await _download('${AppConfig.mapsBaseUrl}/${pack.file}', target, pack.id,
        (d, t) => onProgress('${pack.name} map', d, t));
    settings.update((s) => s.installedPacks[pack.id] = m.version);

    // 2. Offline routing.
    if (pack.routeFile != null) {
      final zip = File('${dir.path}/${pack.routeFile}');
      await _download('${AppConfig.mapsBaseUrl}/${pack.routeFile}', zip, pack.id,
          (d, t) => onProgress('${pack.name} routing', d, t));
      onProgress('Unpacking ${pack.name} routing', 0, 0);
      await _installRouting(pack, zip);
    }

    // 3. Offline search.
    if (pack.searchFile != null) {
      final db = File(await searchDbPath(pack.id));
      final tmp = File('${db.path}.new');
      await _download('${AppConfig.mapsBaseUrl}/${pack.searchFile}', tmp, pack.id,
          (d, t) => onProgress('${pack.name} search', d, t));
      await OfflineSearchCache.closeAll(); // database may be open
      if (db.existsSync()) db.deleteSync();
      tmp.renameSync(db.path);
      _searchKnown.add(pack.id);
    }
    // Make sure the pack is recorded with this version even if a part was missing.
    settings.update((s) => s.installedPacks[pack.id] = m.version);
  }

  Future<void> _installRouting(MapPack pack, File zip) async {
    final tiles = await tilesDir();
    final input = InputFileStream(zip.path);
    final names = <String>[];
    try {
      final archive = ZipDecoder().decodeStream(input);
      for (final f in archive) {
        if (!f.isFile) continue;
        names.add(f.name);
      }
      await OfflineRouter.reset(); // close the engine while tiles change
      await extractArchiveToDisk(archive, tiles);
    } finally {
      await input.close();
    }
    zip.deleteSync();
    final list = await _routeListFile(pack.id);
    await list.writeAsString(jsonEncode({'bbox': pack.bbox, 'files': names}));
    routingBoxes[pack.id] = pack.bbox;
  }

  Future<Set<String>> _routeFiles(String id) async {
    final f = await _routeListFile(id);
    if (!f.existsSync()) return {};
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return (j['files'] as List).cast<String>().toSet();
    } catch (_) {
      return {};
    }
  }

  Future<void> deletePack(String id) async {
    final f = File(await packPath(id));
    if (f.existsSync()) f.deleteSync();
    final part = File('${f.path}.part');
    if (part.existsSync()) part.deleteSync();
    final db = File(await searchDbPath(id));
    await OfflineSearchCache.closeAll();
    if (db.existsSync()) db.deleteSync();
    _searchKnown.remove(id);

    // Remove routing tiles that no other province still needs.
    final mine = await _routeFiles(id);
    if (mine.isNotEmpty) {
      final keep = <String>{};
      for (final other in settings.installedPacks.keys) {
        if (other != id) keep.addAll(await _routeFiles(other));
      }
      await OfflineRouter.reset();
      final tiles = await tilesDir();
      for (final name in mine.difference(keep)) {
        final tf = File('$tiles/$name');
        if (tf.existsSync()) tf.deleteSync();
      }
    }
    final list = await _routeListFile(id);
    if (list.existsSync()) list.deleteSync();
    routingBoxes.remove(id);
    settings.update((s) => s.installedPacks.remove(id));
  }

  /// Size of a partly downloaded pack, so the list can show "resume".
  Future<int> partialBytes(String id) async {
    final part = File('${await packPath(id)}.part');
    return part.existsSync() ? part.lengthSync() : 0;
  }

  bool updateAvailable(MapPack p) {
    final v = settings.installedPacks[p.id];
    if (v == null || manifest == null) return false;
    if (v != manifest!.version) return true;
    // Installed before offline routing/search existed.
    return (p.routeFile != null && !routingBoxes.containsKey(p.id)) ||
        (p.searchFile != null && !_searchKnown.contains(p.id));
  }

  /// Provinces whose search database is on the phone (filled by [refreshParts]).
  final Set<String> _searchKnown = {};

  Future<void> refreshParts() async {
    await loadRoutingInfo();
    _searchKnown.clear();
    for (final id in settings.installedPacks.keys) {
      if (await hasSearch(id)) _searchKnown.add(id);
    }
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
      await refreshParts();
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
