import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../config.dart';
import '../utils/geo.dart';
import 'settings.dart';

/// Keeps the offline search databases open between searches.
class OfflineSearchCache {
  static final Map<String, Database> _open = {};

  static Future<Database> open(String path) async {
    final db = _open[path];
    if (db != null && db.isOpen) return db;
    final created = await openDatabase(path, readOnly: true, singleInstance: false);
    _open[path] = created;
    return created;
  }

  /// Close everything (before a database file is replaced or deleted).
  static Future<void> closeAll() async {
    for (final db in _open.values) {
      try {
        await db.close();
      } catch (_) {}
    }
    _open.clear();
  }
}

/// Address and place search: online (Photon) when there is signal,
/// otherwise the offline databases downloaded with your provinces.
class SearchService {
  /// Set at start-up: lists the offline search databases on the phone.
  Future<List<String>> Function()? offlineDbs;

  /// True if the last results came from the offline databases.
  bool lastWasOffline = false;

  Future<List<Place>> search(String query, {GeoPoint? near}) async {
    try {
      final r = await _online(query, near: near);
      lastWasOffline = false;
      return r;
    } catch (e) {
      final dbs = offlineDbs == null ? const <String>[] : await offlineDbs!();
      if (dbs.isEmpty) rethrow;
      lastWasOffline = true;
      return _offline(query, dbs, near);
    }
  }

  Future<List<Place>> _offline(String query, List<String> dbs, GeoPoint? near) async {
    // "12 main rd" -> 12* main* rd*
    final words = query
        .toLowerCase()
        .replaceAll(RegExp(r"[^\p{L}\p{N}\s]", unicode: true), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return [];
    final match = words.map((w) => '$w*').join(' ');
    final q = query.trim().toLowerCase();
    final scored = <(double, Place)>[];
    final seen = <String>{};
    for (final path in dbs) {
      try {
        final db = await OfflineSearchCache.open(path);
        final rows = await db.rawQuery(
            'SELECT name, context, kind, lat, lon, rank FROM s WHERE s MATCH ? LIMIT 300', [match]);
        for (final r in rows) {
          final name = r['name'] as String? ?? '';
          final ctx = r['context'] as String? ?? '';
          final lat = (r['lat'] as num).toDouble();
          final lon = (r['lon'] as num).toDouble();
          final key = '$name|${lat.toStringAsFixed(3)}|${lon.toStringAsFixed(3)}';
          if (!seen.add(key)) continue;
          var score = ((r['rank'] as num?) ?? 5).toDouble();
          final lower = name.toLowerCase();
          if (lower == q) score -= 4;
          if (lower.startsWith(q)) score -= 2;
          if (!words.every((w) => lower.contains(w))) score += 3; // matched only the area
          if (near != null) score += distanceM(near, GeoPoint(lat, lon)) / 25000;
          final kind = (r['kind'] as String? ?? '');
          final where = [if (kind != 'address' && kind != 'street') kind, if (ctx.isNotEmpty) ctx].join(' · ');
          scored.add((score, Place(name, where, lat, lon)));
        }
      } catch (_) {}
    }
    scored.sort((a, b) => a.$1.compareTo(b.$1));
    return scored.take(15).map((e) => e.$2).toList();
  }

  Future<List<Place>> _online(String query, {GeoPoint? near}) async {
    final q = query.trim();
    if (q.length < 3) return [];
    final b = AppConfig.saBbox;
    final params = <String, String>{
      'q': q,
      'limit': '12',
      'lang': 'en',
      'bbox': '${b[0]},${b[1]},${b[2]},${b[3]}',
    };
    if (near != null) {
      params['lat'] = near.lat.toStringAsFixed(5);
      params['lon'] = near.lon.toStringAsFixed(5);
    }
    final uri = Uri.parse(AppConfig.photonUrl).replace(queryParameters: params);
    final res = await http
        .get(uri, headers: {'User-Agent': AppConfig.userAgent})
        .timeout(const Duration(seconds: 6));
    if (res.statusCode != 200) {
      throw Exception('Search is not available right now (HTTP ${res.statusCode}).');
    }
    final features = (jsonDecode(res.body) as Map<String, dynamic>)['features'] as List;
    final out = <Place>[];
    for (final fRaw in features) {
      final f = fRaw as Map<String, dynamic>;
      final props = f['properties'] as Map<String, dynamic>;
      if ((props['countrycode'] as String?)?.toUpperCase() != 'ZA') continue;
      final coords = (f['geometry'] as Map)['coordinates'] as List;
      final street = [props['housenumber'], props['street']]
          .where((e) => e != null && e.toString().isNotEmpty)
          .join(' ');
      final name = (props['name'] as String?) ?? (street.isNotEmpty ? street : 'Location');
      final parts = <String>[
        if (street.isNotEmpty && street != name) street,
        if (props['district'] != null) props['district'].toString(),
        if (props['city'] != null) props['city'].toString(),
        if (props['state'] != null) props['state'].toString(),
      ];
      out.add(Place(
        name,
        parts.toSet().join(', '),
        (coords[1] as num).toDouble(),
        (coords[0] as num).toDouble(),
      ));
    }
    return out;
  }
}
