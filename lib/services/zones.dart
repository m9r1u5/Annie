import 'dart:math' as math;

import '../utils/geo.dart';

/// An area you never want to drive through.
class AvoidZone {
  final String id;
  String name;
  List<GeoPoint> points; // outline, not closed
  bool enabled;
  bool nightOnly; // only avoid after dark

  AvoidZone({
    required this.id,
    required this.name,
    required this.points,
    this.enabled = true,
    this.nightOnly = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'points': points.map((p) => [p.lat, p.lon]).toList(),
        'enabled': enabled,
        'nightOnly': nightOnly,
      };

  factory AvoidZone.fromJson(Map<String, dynamic> j) => AvoidZone(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Zone',
        points: (j['points'] as List)
            .map((e) => GeoPoint((e[0] as num).toDouble(), (e[1] as num).toDouble()))
            .toList(),
        enabled: j['enabled'] as bool? ?? true,
        nightOnly: j['nightOnly'] as bool? ?? false,
      );

  GeoPoint get centre {
    double lat = 0, lon = 0;
    for (final p in points) {
      lat += p.lat;
      lon += p.lon;
    }
    return GeoPoint(lat / points.length, lon / points.length);
  }

  /// Size of the outline in metres.
  double get perimeterM {
    var d = 0.0;
    for (var i = 0; i < points.length; i++) {
      d += distanceM(points[i], points[(i + 1) % points.length]);
    }
    return d;
  }

  /// The outline pushed outwards by [metres] (a safety margin).
  List<GeoPoint> grown(double metres) {
    if (metres <= 0) return points;
    final c = centre;
    final cosLat = math.cos(c.lat * math.pi / 180);
    return points.map((p) {
      final dy = (p.lat - c.lat) * 111320.0;
      final dx = (p.lon - c.lon) * 111320.0 * cosLat;
      final len = math.sqrt(dx * dx + dy * dy);
      if (len < 1) return p;
      final k = (len + metres) / len;
      return GeoPoint(c.lat + dy * k / 111320.0, c.lon + dx * k / (111320.0 * cosLat));
    }).toList();
  }
}

/// A zone as used for one route request (outline may include the night margin).
class ActiveZone {
  final AvoidZone zone;
  final List<GeoPoint> outline;
  const ActiveZone(this.zone, this.outline);

  bool contains(GeoPoint p) => pointInPolygon(p, outline);
}

/// True if [p] lies inside [poly].
bool pointInPolygon(GeoPoint p, List<GeoPoint> poly) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.lat > p.lat) != (b.lat > p.lat) &&
        p.lon < (b.lon - a.lon) * (p.lat - a.lat) / (b.lat - a.lat) + a.lon) {
      inside = !inside;
    }
  }
  return inside;
}

/// Where a route passes through a zone.
class ZoneHit {
  final AvoidZone zone;
  final double metres;
  final List<List<GeoPoint>> stretches; // the parts of the route inside the zone
  const ZoneHit(this.zone, this.metres, this.stretches);
}

/// Finds every stretch of [route] that runs through any of [zones].
List<ZoneHit> findZoneHits(List<GeoPoint> route, List<ActiveZone> zones) {
  final hits = <ZoneHit>[];
  for (final z in zones) {
    var metres = 0.0;
    final stretches = <List<GeoPoint>>[];
    List<GeoPoint>? current;
    for (var i = 0; i < route.length - 1; i++) {
      final a = route[i], b = route[i + 1];
      final mid = GeoPoint((a.lat + b.lat) / 2, (a.lon + b.lon) / 2);
      final inside = z.contains(a) || z.contains(mid) || z.contains(b);
      if (inside) {
        metres += distanceM(a, b);
        current ??= [a];
        current.add(b);
      } else if (current != null) {
        stretches.add(current);
        current = null;
      }
    }
    if (current != null) stretches.add(current);
    if (stretches.isNotEmpty) hits.add(ZoneHit(z.zone, metres, stretches));
  }
  return hits;
}
