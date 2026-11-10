import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../utils/geo.dart';
import 'settings.dart';
import 'zones.dart';

class Maneuver {
  final int type;
  final String instruction; // English text from the server, for display
  final List<String> streets;
  final double lengthM;
  final double timeS;
  final int beginIndex;
  final int roundaboutExit;
  const Maneuver({
    required this.type,
    required this.instruction,
    required this.streets,
    required this.lengthM,
    required this.timeS,
    required this.beginIndex,
    required this.roundaboutExit,
  });

  String get street => streets.isEmpty ? '' : streets.first;
}

class RouteResult {
  final List<GeoPoint> points;
  final List<Maneuver> maneuvers;
  final double totalM;
  final double totalS;
  final List<double> cum;

  /// Parts of this route that pass through your avoid zones (empty = safe).
  List<ZoneHit> hits = const [];

  /// Extra warnings, e.g. "Your destination is inside ...".
  List<String> notes = const [];

  bool get passesZones => hits.isNotEmpty;

  RouteResult(this.points, this.maneuvers, this.totalM, this.totalS)
      : cum = cumulativeDistances(points);
}

class RoutingException implements Exception {
  final String message;
  final bool offline;
  RoutingException(this.message, {this.offline = false});
  @override
  String toString() => message;
}

/// Routes with Valhalla. Valhalla is used because it supports avoid areas
/// (exclude_polygons), toll/highway/gravel options, and can later run
/// on the phone for fully offline routing.
class RoutingService {
  RoutingService(this.settings);
  final Settings settings;

  /// Finds a route that stays out of your active avoid zones.
  /// If that's impossible, returns the best route anyway with [RouteResult.hits]
  /// filled in so the app can warn you before you drive.
  Future<RouteResult> route(GeoPoint from, GeoPoint to, {double? headingDeg}) async {
    final zones = settings.activeZones();
    final notes = <String>[];
    // A zone around your start or destination can't be avoided completely.
    final excludable = <ActiveZone>[];
    for (final z in zones) {
      if (z.contains(from)) {
        notes.add('You are starting inside "${z.zone.name}".');
      } else if (z.contains(to)) {
        notes.add('Your destination is inside "${z.zone.name}".');
      } else {
        excludable.add(z);
      }
    }

    RouteResult? result;
    if (excludable.isNotEmpty) {
      try {
        result = _parse(await _post(_body(from, to, headingDeg, exclude: excludable)));
      } on RoutingException catch (e) {
        if (e.offline) rethrow;
        // Could not avoid every zone (or the zones are too big for the
        // server). Try a few ordinary routes and keep the safest.
        result = null;
      }
    }
    if (result == null) {
      final j = await _post(_body(from, to, headingDeg, alternates: zones.isEmpty ? 0 : 2));
      final options = <RouteResult>[_parse(j)];
      for (final alt in (j['alternates'] as List?) ?? const []) {
        try {
          options.add(_parse(alt as Map<String, dynamic>));
        } catch (_) {}
      }
      RouteResult? best;
      var bestM = double.infinity;
      for (final o in options) {
        final hits = findZoneHits(o.points, zones);
        final m = hits.fold<double>(0, (a, h) => a + h.metres);
        if (m < bestM - 50 || (best != null && (m - bestM).abs() <= 50 && o.totalS < best.totalS)) {
          best = o;
          bestM = m;
        }
      }
      result = best!;
    }
    result.hits = findZoneHits(result.points, zones);
    result.notes = notes;
    return result;
  }

  /// Turn-by-turn route that follows [path] (e.g. TomTom's faster route).
  /// Returns null if the result doesn't match the path well enough.
  Future<RouteResult?> routeAlong(List<GeoPoint> path, {double? headingDeg}) async {
    if (path.length < 2) return null;
    final cum = cumulativeDistances(path);
    final total = cum.last;
    final locations = <Map<String, dynamic>>[];
    final start = <String, dynamic>{'lat': path.first.lat, 'lon': path.first.lon};
    if (headingDeg != null) {
      start['heading'] = headingDeg.round();
      start['heading_tolerance'] = 45;
    }
    locations.add(start);
    // A point every ~5 km (at most 12), skipping the first and last 500 m.
    final count = (total / 5000).floor().clamp(1, 12);
    var j = 0;
    for (var k = 1; k <= count; k++) {
      final target = total * k / (count + 1);
      if (target < 500 || total - target < 500) continue;
      while (j < cum.length - 2 && cum[j + 1] < target) {
        j++;
      }
      final a = path[j], b = path[j + 1];
      locations.add({
        'lat': a.lat,
        'lon': a.lon,
        'type': 'through',
        'heading': bearingDeg(a, b).round(),
        'heading_tolerance': 45,
      });
    }
    locations.add({'lat': path.last.lat, 'lon': path.last.lon});
    try {
      final r = _parse(await _post(_body(path.first, path.last, headingDeg, locations: locations)));
      // Must be close to the path we asked for (within 15% length).
      if ((r.totalM - total).abs() > total * 0.15 + 300) return null;
      final zones = settings.activeZones();
      r.hits = findZoneHits(r.points, zones);
      if (r.hits.isNotEmpty) return null;
      return r;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _body(GeoPoint from, GeoPoint to, double? headingDeg,
      {List<ActiveZone> exclude = const [], int alternates = 0, List<Map<String, dynamic>>? locations}) {
    final start = <String, dynamic>{'lat': from.lat, 'lon': from.lon};
    if (headingDeg != null) {
      start['heading'] = headingDeg.round();
      start['heading_tolerance'] = 45;
    }
    final body = <String, dynamic>{
      'locations': locations ??
          [
            start,
            {'lat': to.lat, 'lon': to.lon},
          ],
      'costing': 'auto',
      'costing_options': {
        'auto': {
          'use_tolls': settings.avoidTolls ? 0.0 : 0.5,
          'use_highways': settings.avoidHighways ? 0.0 : 1.0,
          'exclude_unpaved': settings.avoidGravel,
        }
      },
      'directions_options': {'units': 'kilometers', 'language': 'en-US'},
    };
    if (exclude.isNotEmpty) {
      body['exclude_polygons'] = exclude.map((z) {
        final ring = z.outline.map((p) => [p.lon, p.lat]).toList();
        ring.add(ring.first); // close the ring
        return ring;
      }).toList();
    }
    if (alternates > 0) body['alternates'] = alternates;
    return body;
  }

  Future<Map<String, dynamic>> _post(Map<String, dynamic> body) async {
    http.Response res;
    try {
      res = await http
          .post(Uri.parse(AppConfig.valhallaUrl),
              headers: {
                'Content-Type': 'application/json',
                'User-Agent': AppConfig.userAgent,
              },
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 25));
    } catch (_) {
      throw RoutingException(
          'Could not reach the route server. Check your data connection.',
          offline: true);
    }
    if (res.statusCode != 200) {
      String msg = 'No route found.';
      try {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        if (j['error'] != null) msg = 'No route found: ${j['error']}';
      } catch (_) {}
      throw RoutingException(msg);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  RouteResult _parse(Map<String, dynamic> json) {
    final trip = json['trip'] as Map<String, dynamic>;
    final points = <GeoPoint>[];
    final maneuvers = <Maneuver>[];
    for (final legRaw in trip['legs'] as List) {
      final leg = legRaw as Map<String, dynamic>;
      final offset = points.isEmpty ? 0 : points.length - 1;
      final legPts = decodePolyline6(leg['shape'] as String);
      points.addAll(points.isEmpty ? legPts : legPts.skip(1));
      for (final mRaw in leg['maneuvers'] as List) {
        final m = mRaw as Map<String, dynamic>;
        maneuvers.add(Maneuver(
          type: (m['type'] as num).toInt(),
          instruction: m['instruction'] as String? ?? '',
          streets: ((m['street_names'] as List?) ?? const [])
              .map((e) => e.toString())
              .toList(),
          lengthM: ((m['length'] as num?) ?? 0).toDouble() * 1000,
          timeS: ((m['time'] as num?) ?? 0).toDouble(),
          beginIndex: (m['begin_shape_index'] as num).toInt() + offset,
          roundaboutExit: ((m['roundabout_exit_count'] as num?) ?? 0).toInt(),
        ));
      }
    }
    final summary = trip['summary'] as Map<String, dynamic>;
    return RouteResult(
      points,
      maneuvers,
      ((summary['length'] as num?) ?? 0).toDouble() * 1000,
      ((summary['time'] as num?) ?? 0).toDouble(),
    );
  }
}
