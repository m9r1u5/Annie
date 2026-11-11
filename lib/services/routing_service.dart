import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../utils/geo.dart';
import 'map_pack_service.dart';
import 'offline_router.dart';
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

  /// Main road(s) this route uses, e.g. "N1 · R59" (by distance driven on them).
  String get via {
    final byLen = <String, double>{};
    for (final m in maneuvers) {
      if (m.streets.isEmpty || m.lengthM <= 0) continue;
      // Prefer route numbers like N1 / R59 / M1 when the road has one.
      final ref = m.streets.firstWhere((s) => RegExp(r'^[NRM]\d+').hasMatch(s), orElse: () => m.streets.first);
      byLen[ref] = (byLen[ref] ?? 0) + m.lengthM;
    }
    final top = byLen.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return top.take(2).map((e) => e.key).join(' · ');
  }

  /// True if this route was planned on the phone (no internet needed).
  bool plannedOffline = false;

  /// The request that produced this route (used to fetch lane guidance).
  Map<String, dynamic>? request;

  /// Lane guidance along the route (filled in by [RoutingService.fetchLanes]).
  List<LanePoint> lanes = const [];

  RouteResult(this.points, this.maneuvers, this.totalM, this.totalS)
      : cum = cumulativeDistances(points);
}

/// One lane at a junction: its arrows and whether it's a good lane for your route.
class Lane {
  final List<String> arrows; // e.g. ["left", "straight"]
  final bool good;
  const Lane(this.arrows, this.good);
}

/// Lane guidance at a point on the route.
class LanePoint {
  final double alongM; // distance from the start of the route
  final List<Lane> lanes;
  const LanePoint(this.alongM, this.lanes);

  /// Only worth showing when some lanes are wrong for your route.
  bool get matters => lanes.any((l) => !l.good) && lanes.any((l) => l.good);
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

  /// Offline routing data on the phone (set at start-up).
  MapPackService? packs;
  bool _lastOffline = false;

  /// Finds a route that stays out of your active avoid zones.
  /// If that's impossible, returns the best route anyway with [RouteResult.hits]
  /// filled in so the app can warn you before you drive.
  Future<RouteResult> route(GeoPoint from, GeoPoint to, {double? headingDeg, List<GeoPoint> vias = const []}) async {
    final zones = settings.activeZones();
    final notes = <String>[];
    // A zone around your start or destination can't be avoided completely.
    final excludable = <ActiveZone>[];
    for (final z in zones) {
      if (z.contains(from)) {
        notes.add('You are starting inside "${z.zone.name}".');
      } else if (z.contains(to)) {
        notes.add('Your destination is inside "${z.zone.name}".');
      } else if (vias.any(z.contains)) {
        notes.add('A town you chose to drive through is inside "${z.zone.name}".');
      } else {
        excludable.add(z);
      }
    }

    RouteResult? result;
    if (excludable.isNotEmpty) {
      try {
        final body = _body(from, to, headingDeg, exclude: excludable, vias: vias);
        result = _parse(await _post(body));
        result.request = body;
      } on RoutingException catch (e) {
        if (e.offline) rethrow;
        // Could not avoid every zone (or the zones are too big for the
        // server). Try a few ordinary routes and keep the safest.
        result = null;
      }
    }
    if (result == null) {
      final body = _body(from, to, headingDeg, alternates: zones.isEmpty ? 0 : 2, vias: vias);
      final j = await _post(body);
      final options = <RouteResult>[_parse(j)..request = (Map.of(body)..remove('alternates'))];
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
    result.plannedOffline = _lastOffline;
    return result;
  }

  /// Turn-by-turn route that follows [path] (e.g. TomTom's faster route).
  /// Returns null if the result doesn't match the path well enough.
  Future<RouteResult?> routeAlong(List<GeoPoint> path, {double? headingDeg}) async {
    if (path.length < 2) return null;
    final total = cumulativeDistances(path).last;
    try {
      final body = alongBody(path, headingDeg: headingDeg);
      final r = _parse(await _post(body));
      r.request = body;
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

  /// A request that makes the router follow [path] (through-points along it).
  Map<String, dynamic> alongBody(List<GeoPoint> path, {double? headingDeg}) {
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
    return _body(path.first, path.last, headingDeg, locations: locations);
  }

  /// Up to 3 different routes to choose from, safest first then quickest.
  Future<List<RouteResult>> routeOptions(GeoPoint from, GeoPoint to,
      {double? headingDeg, List<GeoPoint> vias = const []}) async {
    final zones = settings.activeZones();
    final notes = <String>[];
    final excludable = <ActiveZone>[];
    for (final z in zones) {
      if (z.contains(from)) {
        notes.add('You are starting inside "${z.zone.name}".');
      } else if (z.contains(to)) {
        notes.add('Your destination is inside "${z.zone.name}".');
      } else if (vias.any(z.contains)) {
        notes.add('A town you chose to drive through is inside "${z.zone.name}".');
      } else {
        excludable.add(z);
      }
    }

    List<RouteResult> parseAll(Map<String, dynamic> j, Map<String, dynamic> body) {
      final main = _parse(j)..request = (Map.of(body)..remove('alternates'));
      final out = [main];
      for (final alt in (j['alternates'] as List?) ?? const []) {
        try {
          final r = _parse(alt as Map<String, dynamic>);
          r.request = alongBody(r.points, headingDeg: headingDeg); // for its lane guidance
          out.add(r);
        } catch (_) {}
      }
      return out;
    }

    var options = <RouteResult>[];
    if (excludable.isNotEmpty) {
      try {
        final body = _body(from, to, headingDeg, exclude: excludable, alternates: 2, vias: vias);
        options = parseAll(await _post(body), body);
      } on RoutingException catch (e) {
        if (e.offline) rethrow;
      }
    }
    if (options.isEmpty) {
      final body = _body(from, to, headingDeg, alternates: 2, vias: vias);
      options = parseAll(await _post(body), body);
    }
    for (final o in options) {
      o.hits = findZoneHits(o.points, zones);
      o.notes = notes;
      o.plannedOffline = _lastOffline;
    }
    // Drop near-identical options (same length within 2% and same main roads).
    final unique = <RouteResult>[];
    for (final o in options) {
      if (unique.any((u) => (u.totalM - o.totalM).abs() < o.totalM * 0.02 && u.via == o.via)) continue;
      unique.add(o);
    }
    unique.sort((a, b) {
      final za = a.hits.fold<double>(0, (s, h) => s + h.metres);
      final zb = b.hits.fold<double>(0, (s, h) => s + h.metres);
      if ((za > 0) != (zb > 0)) return za > 0 ? 1 : -1; // safe routes first
      return a.totalS.compareTo(b.totalS);
    });
    return unique.take(3).toList();
  }

  /// Lane guidance for [r] from OpenStreetMap lane data (asks the router
  /// again in its "osrm" format, which includes lanes). Empty if none.
  Future<List<LanePoint>> fetchLanes(RouteResult r) async {
    final req = r.request;
    if (req == null || r.points.length < 2) return const [];
    try {
      final j = await _post({...req, 'format': 'osrm'});
      final out = <LanePoint>[];
      for (final route in ((j['routes'] as List?) ?? const []).take(1)) {
        for (final leg in ((route as Map)['legs'] as List? ?? const [])) {
          for (final step in ((leg as Map)['steps'] as List? ?? const [])) {
            for (final x in ((step as Map)['intersections'] as List? ?? const [])) {
              final lanes = (x as Map)['lanes'] as List?;
              final loc = x['location'] as List?;
              if (lanes == null || lanes.length < 2 || loc == null) continue;
              final p = GeoPoint((loc[1] as num).toDouble(), (loc[0] as num).toDouble());
              final sn = snapToLine(r.points, p);
              if (sn.offRouteM > 25) continue; // not on this route
              final segLen = r.cum[sn.segment + 1] - r.cum[sn.segment];
              final lp = LanePoint(
                r.cum[sn.segment] + segLen * sn.fraction,
                lanes.map((l) {
                  final m = l as Map;
                  final arrows = ((m['indications'] as List?) ?? const ['straight'])
                      .map((e) => e.toString())
                      .toList();
                  return Lane(arrows, m['valid'] == true);
                }).toList(),
              );
              if (lp.matters) out.add(lp);
            }
          }
        }
      }
      out.sort((a, b) => a.alongM.compareTo(b.alongM));
      return out;
    } catch (_) {
      return const [];
    }
  }

  Map<String, dynamic> _body(GeoPoint from, GeoPoint to, double? headingDeg,
      {List<ActiveZone> exclude = const [],
      int alternates = 0,
      List<Map<String, dynamic>>? locations,
      List<GeoPoint> vias = const []}) {
    final start = <String, dynamic>{'lat': from.lat, 'lon': from.lon};
    if (headingDeg != null) {
      start['heading'] = headingDeg.round();
      start['heading_tolerance'] = 45;
    }
    final body = <String, dynamic>{
      'locations': locations ??
          [
            start,
            // Towns you chose to drive through, in order (no stop there).
            for (final v in vias) {'lat': v.lat, 'lon': v.lon, 'type': 'through', 'radius': 150},
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
    // The router can only offer alternatives between two points.
    if (alternates > 0 && vias.isEmpty && locations == null) body['alternates'] = alternates;
    return body;
  }

  /// Plans on the phone when the offline routing data covers every stop,
  /// otherwise (or if that fails) asks the online server.
  Future<Map<String, dynamic>> _post(Map<String, dynamic> body) async {
    final packs = this.packs;
    final stops = (body['locations'] as List)
        .map((l) => GeoPoint(((l as Map)['lat'] as num).toDouble(), (l['lon'] as num).toDouble()))
        .toList();
    String? localError;
    if (packs != null && packs.routingBoxes.isNotEmpty && stops.every(packs.routingCovers)) {
      try {
        final j = await OfflineRouter.route(await packs.tilesDir(), body);
        _lastOffline = true;
        return j;
      } catch (e) {
        localError = e is PlatformException ? (e.message ?? e.code) : e.toString();
      }
    }
    try {
      final j = await _postOnline(body);
      _lastOffline = false;
      return j;
    } on RoutingException catch (e) {
      // No internet, but the phone already gave an answer: report that instead.
      if (e.offline && localError != null) {
        throw RoutingException('No route found: $localError');
      }
      // No internet and no offline data for this trip.
      if (e.offline && packs != null && packs.routingBoxes.isNotEmpty) {
        throw RoutingException(
            'No internet, and this trip goes outside your downloaded provinces. '
            'Download the provinces you drive through under Offline maps.',
            offline: true);
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _postOnline(Map<String, dynamic> body) async {
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
