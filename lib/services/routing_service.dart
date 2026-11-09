import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../utils/geo.dart';
import 'settings.dart';

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
  RouteResult(this.points, this.maneuvers, this.totalM, this.totalS)
      : cum = cumulativeDistances(points);
}

class RoutingException implements Exception {
  final String message;
  RoutingException(this.message);
  @override
  String toString() => message;
}

/// Routes with Valhalla. Valhalla is used because it supports avoid areas
/// (exclude_polygons), toll/highway/gravel options, and can later run
/// on the phone for fully offline routing.
class RoutingService {
  RoutingService(this.settings);
  final Settings settings;

  Future<RouteResult> route(GeoPoint from, GeoPoint to, {double? headingDeg}) async {
    final start = <String, dynamic>{'lat': from.lat, 'lon': from.lon};
    if (headingDeg != null) {
      start['heading'] = headingDeg.round();
      start['heading_tolerance'] = 45;
    }
    final body = {
      'locations': [
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
          'Could not reach the route server. Check your data connection.');
    }
    if (res.statusCode != 200) {
      String msg = 'No route found.';
      try {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        if (j['error'] != null) msg = 'No route found: ${j['error']}';
      } catch (_) {}
      throw RoutingException(msg);
    }

    final trip = (jsonDecode(res.body) as Map<String, dynamic>)['trip']
        as Map<String, dynamic>;
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
