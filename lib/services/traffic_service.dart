import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../config.dart';
import '../utils/geo.dart';
import 'settings.dart';
import 'zones.dart';

/// A faster way that TomTom found, with live traffic.
class TrafficAlt {
  final List<GeoPoint> points;
  final double timeS;
  final double lengthM;
  const TrafficAlt(this.points, this.timeS, this.lengthM);
}

/// Live traffic for a route.
class TrafficCheck {
  final double timeS; // travel time with traffic for your route
  final double delayS; // how much of that is traffic delay
  final TrafficAlt? faster; // a quicker route that avoids your zones
  const TrafficCheck(this.timeS, this.delayS, this.faster);

  double get savingS => faster == null ? 0 : timeS - faster!.timeS;
}

/// An accident, roadworks, closure, jam, etc.
class Incident {
  final GeoPoint point;
  final int category;
  final String text;
  final double delayS;
  const Incident(this.point, this.category, this.text, this.delayS);

  String get label {
    switch (category) {
      case 1:
        return 'Accident';
      case 2:
        return 'Fog';
      case 3:
        return 'Danger';
      case 4:
        return 'Rain';
      case 5:
        return 'Ice';
      case 6:
        return 'Traffic jam';
      case 7:
        return 'Lane closed';
      case 8:
        return 'Road closed';
      case 9:
        return 'Roadworks';
      case 10:
        return 'Wind';
      case 11:
        return 'Flooding';
      case 14:
        return 'Broken-down vehicle';
      default:
        return 'Incident';
    }
  }

  String get color {
    switch (category) {
      case 1:
      case 8:
        return '#D32F2F';
      case 6:
        return '#FB8C00';
      case 7:
      case 9:
        return '#F9A825';
      default:
        return '#7E57C2';
    }
  }
}

class TrafficException implements Exception {
  final String message;
  TrafficException(this.message);
  @override
  String toString() => message;
}

/// TomTom live traffic (free developer key, about 2,500 requests a day).
class TrafficService {
  TrafficService(this.settings);
  final Settings settings;

  String get _key => settings.tomtomKey.trim();

  /// Checks that a key works. Returns null if fine, otherwise the problem.
  Future<String?> testKey(String key) async {
    final uri = Uri.parse('https://api.tomtom.com/traffic/services/5/incidentDetails').replace(
      queryParameters: {
        'key': key.trim(),
        'bbox': '28.00,-26.25,28.10,-26.15',
        'fields': '{incidents{type}}',
      },
    );
    try {
      final r = await http.get(uri).timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) return null;
      if (r.statusCode == 401 || r.statusCode == 403) {
        return 'TomTom says this key is not valid. Copy it again from your TomTom dashboard.';
      }
      return 'TomTom answered with error ${r.statusCode}.';
    } catch (_) {
      return 'Could not reach TomTom. Check your data connection.';
    }
  }

  /// Picks at most [max] points spread along [pts], always keeping both ends.
  static List<GeoPoint> _thin(List<GeoPoint> pts, int max) {
    if (pts.length <= max) return pts;
    final out = <GeoPoint>[];
    final step = (pts.length - 1) / (max - 1);
    for (var i = 0; i < max; i++) {
      out.add(pts[(i * step).round().clamp(0, pts.length - 1)]);
    }
    return out;
  }

  /// Travel time with traffic for [path] (your route from here to the end),
  /// plus a faster route if TomTom finds one that stays out of your zones.
  Future<TrafficCheck?> check(List<GeoPoint> path) async {
    if (_key.isEmpty || path.length < 2) return null;
    final pts = _thin(path, 150);
    final a = pts.first, b = pts.last;
    final params = <String, dynamic>{
      'key': _key,
      'traffic': 'true',
      'travelMode': 'car',
      'routeType': 'fastest',
      'maxAlternatives': '2',
      'alternativeType': 'betterRoute',
      'minDeviationDistance': '0',
      'routeRepresentation': 'polyline',
      'avoid': [
        if (settings.avoidTolls) 'tollRoads',
        if (settings.avoidHighways) 'motorways',
        if (settings.avoidGravel) 'unpavedRoads',
      ],
    };
    if ((params['avoid'] as List).isEmpty) params.remove('avoid');
    final uri = Uri.parse('https://api.tomtom.com/routing/1/calculateRoute/'
            '${a.lat},${a.lon}:${b.lat},${b.lon}/json')
        .replace(queryParameters: params);

    final zones = settings.activeZones();
    final body = <String, dynamic>{
      'supportingPoints': pts.map((p) => {'latitude': p.lat, 'longitude': p.lon}).toList(),
    };
    // TomTom can avoid up to 10 rectangles: use a box around each zone.
    if (zones.isNotEmpty && zones.length <= 10) {
      body['avoidAreas'] = {
        'rectangles': zones.map((z) {
          var s = 90.0, w = 180.0, n = -90.0, e = -180.0;
          for (final p in z.outline) {
            s = math.min(s, p.lat);
            n = math.max(n, p.lat);
            w = math.min(w, p.lon);
            e = math.max(e, p.lon);
          }
          return {
            'southWestCorner': {'latitude': s, 'longitude': w},
            'northEastCorner': {'latitude': n, 'longitude': e},
          };
        }).toList(),
      };
    }

    http.Response r;
    try {
      r = await http
          .post(uri,
              headers: {'Content-Type': 'application/json', 'User-Agent': AppConfig.userAgent},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      return null;
    }
    if (r.statusCode != 200) return null;

    final routes = ((jsonDecode(r.body) as Map<String, dynamic>)['routes'] as List?) ?? const [];
    if (routes.isEmpty) return null;
    final ref = routes.first as Map<String, dynamic>;
    final refSum = ref['summary'] as Map<String, dynamic>;
    final timeS = ((refSum['travelTimeInSeconds'] as num?) ?? 0).toDouble();
    final delayS = ((refSum['trafficDelayInSeconds'] as num?) ?? 0).toDouble();

    TrafficAlt? best;
    for (final raw in routes.skip(1)) {
      final route = raw as Map<String, dynamic>;
      final sum = route['summary'] as Map<String, dynamic>;
      final altPts = <GeoPoint>[];
      for (final leg in (route['legs'] as List? ?? const [])) {
        for (final p in ((leg as Map)['points'] as List? ?? const [])) {
          altPts.add(GeoPoint((p['latitude'] as num).toDouble(), (p['longitude'] as num).toDouble()));
        }
      }
      if (altPts.length < 2) continue;
      if (findZoneHits(altPts, zones).isNotEmpty) continue; // never trade safety for time
      final alt = TrafficAlt(
        altPts,
        ((sum['travelTimeInSeconds'] as num?) ?? 0).toDouble(),
        ((sum['lengthInMeters'] as num?) ?? 0).toDouble(),
      );
      if (alt.timeS < timeS && (best == null || alt.timeS < best.timeS)) best = alt;
    }
    return TrafficCheck(timeS, delayS, best);
  }

  /// Incidents inside a box (west, south, east, north). TomTom allows up to
  /// about 10,000 km², so big boxes are shrunk around [focus].
  Future<List<Incident>> incidents(double w, double s, double e, double n, GeoPoint focus) async {
    if (_key.isEmpty) return const [];
    double areaKm2() =>
        (e - w) * 111.32 * math.cos(((s + n) / 2) * math.pi / 180) * (n - s) * 111.32;
    if (areaKm2() > 9500) {
      const half = 0.4; // about 45 km each way
      w = math.max(w, focus.lon - half);
      e = math.min(e, focus.lon + half);
      s = math.max(s, focus.lat - half);
      n = math.min(n, focus.lat + half);
      if (areaKm2() > 9500 || e <= w || n <= s) {
        w = focus.lon - half;
        e = focus.lon + half;
        s = focus.lat - half;
        n = focus.lat + half;
      }
    }
    final uri = Uri.parse('https://api.tomtom.com/traffic/services/5/incidentDetails').replace(
      queryParameters: {
        'key': _key,
        'bbox': '${w.toStringAsFixed(5)},${s.toStringAsFixed(5)},${e.toStringAsFixed(5)},${n.toStringAsFixed(5)}',
        'fields': '{incidents{type,geometry{type,coordinates},properties{iconCategory,events{description},from,to,delay}}}',
        'language': 'en-GB',
      },
    );
    try {
      final r = await http.get(uri).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return const [];
      final list = ((jsonDecode(r.body) as Map<String, dynamic>)['incidents'] as List?) ?? const [];
      final out = <Incident>[];
      for (final raw in list) {
        final f = raw as Map<String, dynamic>;
        final g = f['geometry'] as Map<String, dynamic>?;
        final props = (f['properties'] as Map<String, dynamic>?) ?? const {};
        if (g == null) continue;
        List c = g['coordinates'] as List;
        if (g['type'] == 'LineString') c = c.first as List;
        final point = GeoPoint((c[1] as num).toDouble(), (c[0] as num).toDouble());
        final events = (props['events'] as List?) ?? const [];
        final desc = events.isEmpty ? '' : ((events.first as Map)['description'] as String? ?? '');
        final where = props['from'] != null ? ' near ${props['from']}' : '';
        out.add(Incident(
          point,
          ((props['iconCategory'] as num?) ?? 0).toInt(),
          '$desc$where'.trim(),
          ((props['delay'] as num?) ?? 0).toDouble(),
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}
