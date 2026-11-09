import 'dart:math' as math;

class GeoPoint {
  final double lat;
  final double lon;
  const GeoPoint(this.lat, this.lon);

  Map<String, dynamic> toJson() => {'lat': lat, 'lon': lon};
  factory GeoPoint.fromJson(Map<String, dynamic> j) =>
      GeoPoint((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble());
}

const double _earthRadius = 6371000.0;

double _rad(double d) => d * math.pi / 180.0;

/// Distance in metres between two points.
double distanceM(GeoPoint a, GeoPoint b) {
  final dLat = _rad(b.lat - a.lat);
  final dLon = _rad(b.lon - a.lon);
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(a.lat)) *
          math.cos(_rad(b.lat)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * _earthRadius * math.asin(math.min(1.0, math.sqrt(h)));
}

/// Bearing in degrees (0 = north) from a to b.
double bearingDeg(GeoPoint a, GeoPoint b) {
  final y = math.sin(_rad(b.lon - a.lon)) * math.cos(_rad(b.lat));
  final x = math.cos(_rad(a.lat)) * math.sin(_rad(b.lat)) -
      math.sin(_rad(a.lat)) * math.cos(_rad(b.lat)) * math.cos(_rad(b.lon - a.lon));
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

/// Decodes a Valhalla polyline (precision 6).
List<GeoPoint> decodePolyline6(String encoded) {
  final points = <GeoPoint>[];
  int index = 0, lat = 0, lon = 0;
  while (index < encoded.length) {
    int shift = 0, result = 0, b;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
    shift = 0;
    result = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    lon += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
    points.add(GeoPoint(lat / 1e6, lon / 1e6));
  }
  return points;
}

/// Result of snapping a position onto a route line.
class Snap {
  final int segment; // index of the segment start point
  final double fraction; // 0..1 along that segment
  final double offRouteM; // distance from the line
  const Snap(this.segment, this.fraction, this.offRouteM);
}

/// Snaps [p] to the polyline, searching segments [from]..[to].
Snap snapToLine(List<GeoPoint> line, GeoPoint p, {int from = 0, int? to}) {
  final end = math.min(to ?? line.length - 1, line.length - 1);
  // Local flat projection in metres around p.
  final cosLat = math.cos(_rad(p.lat));
  double mx(GeoPoint g) => _rad(g.lon - p.lon) * _earthRadius * cosLat;
  double my(GeoPoint g) => _rad(g.lat - p.lat) * _earthRadius;

  var best = Snap(math.max(0, from), 0, double.infinity);
  for (var i = math.max(0, from); i < end; i++) {
    final ax = mx(line[i]), ay = my(line[i]);
    final bx = mx(line[i + 1]), by = my(line[i + 1]);
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    var t = len2 == 0 ? 0.0 : (-(ax * dx + ay * dy)) / len2;
    t = t.clamp(0.0, 1.0).toDouble();
    final px = ax + t * dx, py = ay + t * dy;
    final d = math.sqrt(px * px + py * py);
    if (d < best.offRouteM) best = Snap(i, t, d);
  }
  return best;
}

/// Cumulative distance (metres) from the start to each point.
List<double> cumulativeDistances(List<GeoPoint> line) {
  final out = List<double>.filled(line.length, 0);
  for (var i = 1; i < line.length; i++) {
    out[i] = out[i - 1] + distanceM(line[i - 1], line[i]);
  }
  return out;
}

String formatDistance(double m) {
  if (m >= 10000) return '${(m / 1000).round()} km';
  if (m >= 1000) return '${(m / 1000).toStringAsFixed(1)} km';
  if (m >= 100) return '${(m / 50).round() * 50} m';
  return '${(m / 10).round() * 10} m';
}

String formatDuration(double seconds) {
  final mins = (seconds / 60).round();
  if (mins < 60) return '$mins min';
  return '${mins ~/ 60} h ${mins % 60} min';
}

String formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}
