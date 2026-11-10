import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../utils/geo.dart';
import 'search_service.dart';
import 'settings.dart';

/// A kind of place you can look for (fuel, hospital, ...).
class PlaceCategory {
  final String label;
  final IconData icon;
  final Color color;
  final String tomtomQuery; // what we ask TomTom for
  final List<String> osmKinds; // matching kinds in the offline search data
  const PlaceCategory(this.label, this.icon, this.color, this.tomtomQuery, this.osmKinds);
}

const placeCategories = <PlaceCategory>[
  PlaceCategory('Fuel', Icons.local_gas_station, Color(0xFFE53935), 'petrol station', ['fuel']),
  PlaceCategory('Shops', Icons.shopping_cart, Color(0xFF43A047), 'supermarket',
      ['supermarket', 'convenience', 'mall', 'department store']),
  PlaceCategory('Hospital', Icons.local_hospital, Color(0xFFD81B60), 'hospital',
      ['hospital', 'clinic', 'doctors']),
  PlaceCategory('Police', Icons.local_police, Color(0xFF1E88E5), 'police station', ['police']),
  PlaceCategory('Pharmacy', Icons.local_pharmacy, Color(0xFF00897B), 'pharmacy', ['pharmacy', 'chemist']),
  PlaceCategory('ATM & bank', Icons.atm, Color(0xFF5E35B1), 'atm', ['atm', 'bank']),
  PlaceCategory('Food', Icons.restaurant, Color(0xFFFB8C00), 'restaurant',
      ['restaurant', 'fast food', 'cafe']),
  PlaceCategory('Parking', Icons.local_parking, Color(0xFF3949AB), 'parking', ['parking']),
  PlaceCategory('Car repair', Icons.car_repair, Color(0xFF6D4C41), 'car repair', ['car repair', 'tyres', 'car parts']),
  PlaceCategory('Hotel', Icons.hotel, Color(0xFF8E24AA), 'hotel', ['hotel', 'guest house', 'motel']),
  PlaceCategory('EV charging', Icons.ev_station, Color(0xFF00ACC1), 'electric vehicle station',
      ['charging station']),
];

/// One place found.
class FoundPlace {
  final String name;
  final String address;
  final GeoPoint point;
  final double? distanceM; // straight-line from you
  final double? detourS; // extra time if you stop here on your route
  final String? phone;
  final bool? openNow; // null = unknown
  final String? hoursText; // e.g. "Open until 22:00"
  const FoundPlace({
    required this.name,
    required this.address,
    required this.point,
    this.distanceM,
    this.detourS,
    this.phone,
    this.openNow,
    this.hoursText,
  });

  Place toPlace() => Place(name, address, point.lat, point.lon);
}

/// Finds places near you or along your route: TomTom online, offline data as backup.
class PlacesService {
  PlacesService(this.settings, this.offlineDbs);
  final Settings settings;
  final Future<List<String>> Function() offlineDbs;

  /// True if the last results came from the offline data.
  bool lastWasOffline = false;

  String get _key => settings.tomtomKey.trim();

  Future<List<FoundPlace>> nearby(PlaceCategory c, GeoPoint here) async {
    if (_key.isNotEmpty) {
      try {
        final uri = Uri.parse('https://api.tomtom.com/search/2/categorySearch/'
                '${Uri.encodeComponent(c.tomtomQuery)}.json')
            .replace(queryParameters: {
          'key': _key,
          'lat': '${here.lat}',
          'lon': '${here.lon}',
          'radius': '25000',
          'limit': '30',
          'countrySet': 'ZA',
          'openingHours': 'nextSevenDays',
        });
        final r = await http.get(uri, headers: {'User-Agent': AppConfig.userAgent}).timeout(const Duration(seconds: 8));
        if (r.statusCode == 200) {
          final out = _parse(r.body, here);
          out.sort((a, b) => (a.distanceM ?? 1e9).compareTo(b.distanceM ?? 1e9));
          lastWasOffline = false;
          return out;
        }
      } catch (_) {}
    }
    lastWasOffline = true;
    return _offlineNear(c, here);
  }

  /// Any business or place by name ("Mica", "Engen"), near you or along your route.
  Future<List<FoundPlace>> byName(String text, GeoPoint here, {List<GeoPoint> route = const []}) async {
    final q = text.trim();
    if (q.length < 2) return const [];
    if (_key.isNotEmpty) {
      try {
        http.Response r;
        if (route.length >= 2) {
          final uri = Uri.parse('https://api.tomtom.com/search/2/searchAlongRoute/${Uri.encodeComponent(q)}.json')
              .replace(queryParameters: {
            'key': _key,
            'maxDetourTime': '1200',
            'limit': '20',
            'openingHours': 'nextSevenDays',
            'sortBy': 'detourOffset',
            'detourOffset': 'true',
          });
          r = await http
              .post(uri,
                  headers: {'Content-Type': 'application/json', 'User-Agent': AppConfig.userAgent},
                  body: jsonEncode({
                    'route': {'points': _thin(route, 400).map((p) => {'lat': p.lat, 'lon': p.lon}).toList()},
                  }))
              .timeout(const Duration(seconds: 10));
        } else {
          final uri = Uri.parse('https://api.tomtom.com/search/2/poiSearch/${Uri.encodeComponent(q)}.json')
              .replace(queryParameters: {
            'key': _key,
            'lat': '${here.lat}',
            'lon': '${here.lon}',
            'radius': '40000',
            'limit': '30',
            'countrySet': 'ZA',
            'typeahead': 'true',
            'openingHours': 'nextSevenDays',
          });
          r = await http.get(uri, headers: {'User-Agent': AppConfig.userAgent}).timeout(const Duration(seconds: 8));
        }
        if (r.statusCode == 200) {
          final out = _parse(r.body, here);
          if (route.length < 2) out.sort((a, b) => (a.distanceM ?? 1e9).compareTo(b.distanceM ?? 1e9));
          lastWasOffline = false;
          return out;
        }
      } catch (_) {}
    }
    // Offline: match names in your downloaded search data, nearest first.
    lastWasOffline = true;
    final words = q
        .toLowerCase()
        .replaceAll(RegExp(r"[^\p{L}\p{N}\s]", unicode: true), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty);
    final match = words.map((w) => '$w*').join(' ');
    if (match.isEmpty) return const [];
    final out = <FoundPlace>[];
    for (final path in await offlineDbs()) {
      try {
        final db = await OfflineSearchCache.open(path);
        final rows = await db.rawQuery(
            "SELECT name, context, kind, lat, lon FROM s WHERE s MATCH ? AND kind NOT IN ('street','address') LIMIT 400",
            [match]);
        out.addAll(rows.map((r) => _fromRow(r, here)));
      } catch (_) {}
    }
    out.removeWhere((p) => (p.distanceM ?? 0) > 60000);
    out.sort((a, b) => a.distanceM!.compareTo(b.distanceM!));
    return out.take(30).toList();
  }

  /// Places near the rest of your route, ordered by how far ahead they are.
  Future<List<FoundPlace>> alongRoute(PlaceCategory c, List<GeoPoint> route, GeoPoint here) async {
    if (route.length < 2) return nearby(c, here);
    if (_key.isNotEmpty) {
      try {
        final pts = _thin(route, 400);
        final uri = Uri.parse('https://api.tomtom.com/search/2/searchAlongRoute/'
                '${Uri.encodeComponent(c.tomtomQuery)}.json')
            .replace(queryParameters: {
          'key': _key,
          'maxDetourTime': '900',
          'limit': '20',
          'openingHours': 'nextSevenDays',
          'sortBy': 'detourOffset',
          'detourOffset': 'true',
        });
        final body = jsonEncode({
          'route': {'points': pts.map((p) => {'lat': p.lat, 'lon': p.lon}).toList()},
        });
        final r = await http
            .post(uri, headers: {'Content-Type': 'application/json', 'User-Agent': AppConfig.userAgent}, body: body)
            .timeout(const Duration(seconds: 10));
        if (r.statusCode == 200) {
          lastWasOffline = false;
          return _parse(r.body, here);
        }
      } catch (_) {}
    }
    lastWasOffline = true;
    return _offlineAlong(c, route, here);
  }

  static List<GeoPoint> _thin(List<GeoPoint> pts, int max) {
    if (pts.length <= max) return pts;
    final step = (pts.length - 1) / (max - 1);
    return [for (var i = 0; i < max; i++) pts[(i * step).round().clamp(0, pts.length - 1)]];
  }

  List<FoundPlace> _parse(String json, GeoPoint here) {
    final results = ((jsonDecode(json) as Map<String, dynamic>)['results'] as List?) ?? const [];
    final out = <FoundPlace>[];
    for (final raw in results) {
      final r = raw as Map<String, dynamic>;
      final poi = (r['poi'] as Map?) ?? const {};
      final pos = r['position'] as Map?;
      if (pos == null) continue;
      final p = GeoPoint((pos['lat'] as num).toDouble(), (pos['lon'] as num).toDouble());
      final brand = ((poi['brands'] as List?) ?? const []).isNotEmpty
          ? ((poi['brands'] as List).first as Map)['name'] as String?
          : null;
      var name = (poi['name'] as String?) ?? brand ?? 'Place';
      if (brand != null && !name.toLowerCase().contains(brand.toLowerCase())) name = '$brand $name';
      final hours = _openState(poi['openingHours'] as Map?);
      out.add(FoundPlace(
        name: name,
        address: ((r['address'] as Map?)?['freeformAddress'] as String?) ?? '',
        point: p,
        distanceM: distanceM(here, p),
        detourS: (r['detourTime'] as num?)?.toDouble(),
        phone: poi['phone'] as String?,
        openNow: hours?.$1,
        hoursText: hours?.$2,
      ));
    }
    return out;
  }

  /// (open now?, "Open until 22:00" / "Closed · opens 07:00") from TomTom opening hours.
  (bool, String)? _openState(Map? oh) {
    final ranges = (oh?['timeRanges'] as List?) ?? const [];
    if (ranges.isEmpty) return null;
    DateTime? t(Map? m) {
      if (m == null) return null;
      final d = DateTime.tryParse(m['date'] as String? ?? '');
      if (d == null) return null;
      return DateTime(d.year, d.month, d.day, (m['hour'] as num?)?.toInt() ?? 0, (m['minute'] as num?)?.toInt() ?? 0);
    }

    String hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final now = DateTime.now();
    DateTime? nextOpen;
    for (final raw in ranges) {
      final s = t((raw as Map)['startTime'] as Map?);
      final e = t(raw['endTime'] as Map?);
      if (s == null || e == null) continue;
      if (!now.isBefore(s) && now.isBefore(e)) {
        final allDay = e.difference(s).inHours >= 23;
        return (true, allDay ? 'Open 24 hours' : 'Open until ${hm(e)}');
      }
      if (s.isAfter(now) && (nextOpen == null || s.isBefore(nextOpen))) nextOpen = s;
    }
    if (nextOpen == null) return (false, 'Closed');
    final sameDay = nextOpen.day == now.day;
    return (false, sameDay ? 'Closed · opens ${hm(nextOpen)}' : 'Closed · opens ${_dayName(nextOpen)} ${hm(nextOpen)}');
  }

  static String _dayName(DateTime d) => const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1];

  // ---------------- Offline ----------------

  Future<List<Map<String, Object?>>> _offlineRows(PlaceCategory c, double w, double s, double e, double n) async {
    final rows = <Map<String, Object?>>[];
    final marks = List.filled(c.osmKinds.length, '?').join(',');
    for (final path in await offlineDbs()) {
      try {
        final db = await OfflineSearchCache.open(path);
        rows.addAll(await db.rawQuery(
          'SELECT name, context, kind, lat, lon FROM s WHERE kind IN ($marks) '
          'AND lat BETWEEN ? AND ? AND lon BETWEEN ? AND ? LIMIT 2000',
          [...c.osmKinds, s, n, w, e],
        ));
      } catch (_) {}
    }
    return rows;
  }

  FoundPlace _fromRow(Map<String, Object?> r, GeoPoint here) {
    final p = GeoPoint((r['lat'] as num).toDouble(), (r['lon'] as num).toDouble());
    return FoundPlace(
      name: r['name'] as String? ?? 'Place',
      address: [r['kind'], r['context']].where((x) => x != null && '$x'.isNotEmpty).join(' · '),
      point: p,
      distanceM: distanceM(here, p),
    );
  }

  Future<List<FoundPlace>> _offlineNear(PlaceCategory c, GeoPoint here) async {
    for (final km in [10.0, 30.0]) {
      final dLat = km / 111.0;
      final dLon = km / (111.0 * math.cos(here.lat * math.pi / 180));
      final rows = await _offlineRows(c, here.lon - dLon, here.lat - dLat, here.lon + dLon, here.lat + dLat);
      final out = rows.map((r) => _fromRow(r, here)).toList()
        ..sort((a, b) => a.distanceM!.compareTo(b.distanceM!));
      if (out.length >= 5 || km == 30.0) return out.take(30).toList();
    }
    return const [];
  }

  Future<List<FoundPlace>> _offlineAlong(PlaceCategory c, List<GeoPoint> route, GeoPoint here) async {
    double w = 180, s = 90, e = -180, n = -90;
    for (final p in route) {
      w = math.min(w, p.lon);
      e = math.max(e, p.lon);
      s = math.min(s, p.lat);
      n = math.max(n, p.lat);
    }
    const pad = 0.02;
    final rows = await _offlineRows(c, w - pad, s - pad, e + pad, n + pad);
    final cum = cumulativeDistances(route);
    final found = <(double, FoundPlace)>[];
    for (final r in rows) {
      final f = _fromRow(r, here);
      final sn = snapToLine(route, f.point);
      if (sn.offRouteM > 1500) continue;
      final ahead = cum[sn.segment] + (cum[sn.segment + 1] - cum[sn.segment]) * sn.fraction;
      found.add((ahead, FoundPlace(
        name: f.name,
        address: f.address,
        point: f.point,
        distanceM: f.distanceM,
        detourS: 2 * sn.offRouteM / (35 / 3.6), // rough: there and back at ~35 km/h
      )));
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return found.take(30).map((e) => e.$2).toList();
  }
}
