import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart';

import '../utils/geo.dart';
import 'routing_service.dart';

class TrailPoint {
  final double lat;
  final double lon;
  final DateTime time;
  const TrailPoint(this.lat, this.lon, this.time);

  GeoPoint get point => GeoPoint(lat, lon);

  List<num> toJson() => [lat, lon, time.millisecondsSinceEpoch];
  factory TrailPoint.fromJson(List j) => TrailPoint(
      (j[0] as num).toDouble(),
      (j[1] as num).toDouble(),
      DateTime.fromMillisecondsSinceEpoch((j[2] as num).toInt()));
}

/// Your breadcrumb trail: where you drove in the last 12 hours,
/// so you can get out of an area exactly the way you came in.
class TrailService {
  static const keep = Duration(hours: 12);

  /// A stop this long starts a new trip.
  static const tripGap = Duration(minutes: 10);

  final List<TrailPoint> points = [];
  Timer? _saveTimer;
  bool _dirty = false;

  Future<File> _file() async {
    final d = await getApplicationSupportDirectory();
    return File('${d.path}/trail.json');
  }

  Future<void> load() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return;
      final list = jsonDecode(await f.readAsString()) as List;
      points
        ..clear()
        ..addAll(list.map((e) => TrailPoint.fromJson(e as List)));
      _trim();
    } catch (_) {}
  }

  void _trim() {
    final cutoff = DateTime.now().subtract(keep);
    points.removeWhere((p) => p.time.isBefore(cutoff));
  }

  /// Adds a GPS fix if you've moved far enough and the fix is good.
  void add(double lat, double lon, double speedMs, double accuracyM) {
    if (accuracyM > 35 || speedMs < 1.5) return;
    final now = DateTime.now();
    if (points.isNotEmpty) {
      final last = points.last;
      if (distanceM(last.point, GeoPoint(lat, lon)) < 15) return;
    }
    points.add(TrailPoint(lat, lon, now));
    _dirty = true;
    _saveTimer ??= Timer(const Duration(seconds: 20), save);
  }

  Future<void> save() async {
    _saveTimer = null;
    if (!_dirty) return;
    _dirty = false;
    _trim();
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(points.map((p) => p.toJson()).toList()));
    } catch (_) {}
  }

  Future<void> clear() async {
    points.clear();
    _dirty = true;
    await save();
  }

  /// Index where the current trip began (after the last long stop).
  int tripStartIndex() {
    for (var i = points.length - 1; i > 0; i--) {
      if (points[i].time.difference(points[i - 1].time) > tripGap) return i;
    }
    return 0;
  }

  /// Index of the first point at most [back] ago (within this trip).
  int indexAgo(Duration back) {
    final start = tripStartIndex();
    final since = DateTime.now().subtract(back);
    for (var i = start; i < points.length; i++) {
      if (!points[i].time.isBefore(since)) return i;
    }
    return points.length - 1;
  }

  /// The trail from [from] (your position now) back to point [toIndex],
  /// in the order you'll drive it.
  List<GeoPoint> pathBack(GeoPoint from, int toIndex) {
    if (points.isEmpty) return const [];
    final out = <GeoPoint>[from];
    for (var i = points.length - 1; i >= toIndex; i--) {
      out.add(points[i].point);
    }
    return _simplify(out, 8);
  }

  /// Two trail points further apart than this means GPS wasn't recording
  /// in between (app closed, screen off, tunnel). Never draw a straight line.
  static const gapM = 250.0;

  /// Like [pathBack], but every gap in the recording is filled with real
  /// roads from [fill] (the router). Returns the path, how many gaps there
  /// were and how many could not be filled.
  Future<(List<GeoPoint>, int, int)> pathBackOnRoads(
      GeoPoint from, int toIndex, Future<List<GeoPoint>?> Function(GeoPoint a, GeoPoint b) fill) async {
    if (points.isEmpty) return (const <GeoPoint>[], 0, 0);
    final raw = <GeoPoint>[from];
    for (var i = points.length - 1; i >= toIndex; i--) {
      raw.add(points[i].point);
    }
    // Split into pieces that were recorded continuously.
    final runs = <List<GeoPoint>>[
      [raw.first]
    ];
    for (var i = 1; i < raw.length; i++) {
      if (distanceM(raw[i - 1], raw[i]) > gapM) runs.add(<GeoPoint>[]);
      runs.last.add(raw[i]);
    }
    final out = <GeoPoint>[];
    var unfilled = 0;
    for (var k = 0; k < runs.length; k++) {
      final run = _simplify(runs[k], 8);
      if (k > 0 && out.isNotEmpty) {
        final a = out.last, b = run.first;
        List<GeoPoint>? road;
        try {
          road = await fill(a, b);
        } catch (_) {}
        if (road != null && road.length >= 2) {
          out.addAll(road.skip(1));
        } else {
          unfilled++;
        }
      }
      out.addAll(run);
    }
    return (out, runs.length - 1, unfilled);
  }

  /// Trail of the last [span] for drawing on the map.
  List<GeoPoint> recent(Duration span) {
    final since = DateTime.now().subtract(span);
    return points.where((p) => !p.time.isBefore(since)).map((p) => p.point).toList();
  }

  double lengthM(List<GeoPoint> path) => path.isEmpty ? 0 : cumulativeDistances(path).last;

  // ---------------- Turn-by-turn along the exact trail ----------------

  /// A route that follows [path] exactly, with turn instructions worked out
  /// from the shape of the trail (no street names, works offline).
  RouteResult routeFromPath(List<GeoPoint> path) {
    final pts = path;
    final cum = cumulativeDistances(pts);
    final maneuvers = <Maneuver>[
      const Maneuver(
          type: 1, instruction: 'Follow your trail', streets: [], lengthM: 0, timeS: 0, beginIndex: 0, roundaboutExit: 0),
    ];
    var lastTurnAt = -1000.0;
    for (var i = 1; i < pts.length - 1; i++) {
      // Compare direction ~30 m before and after this point (ignores GPS wobble).
      final before = _pointBack(pts, cum, i, 30);
      final after = _pointAhead(pts, cum, i, 30);
      if (before == null || after == null) continue;
      final b1 = bearingDeg(before, pts[i]);
      final b2 = bearingDeg(pts[i], after);
      var turn = b2 - b1;
      while (turn > 180) {
        turn -= 360;
      }
      while (turn < -180) {
        turn += 360;
      }
      final a = turn.abs();
      if (a < 35 || cum[i] - lastTurnAt < 40) continue;
      int type;
      if (a > 150) {
        type = 12; // U-turn
      } else if (a > 110) {
        type = turn > 0 ? 11 : 14;
      } else if (a > 55) {
        type = turn > 0 ? 10 : 15;
      } else {
        type = turn > 0 ? 9 : 16;
      }
      maneuvers.add(Maneuver(
          type: type, instruction: '', streets: const [], lengthM: 0, timeS: 0, beginIndex: i, roundaboutExit: 0));
      lastTurnAt = cum[i];
    }
    maneuvers.add(Maneuver(
        type: 4,
        instruction: 'You are back',
        streets: const [],
        lengthM: 0,
        timeS: 0,
        beginIndex: pts.length - 1,
        roundaboutExit: 0));
    final total = cum.last;
    return RouteResult(pts, maneuvers, total, total / (40 / 3.6)); // ~40 km/h
  }

  GeoPoint? _pointBack(List<GeoPoint> pts, List<double> cum, int i, double m) {
    for (var j = i - 1; j >= 0; j--) {
      if (cum[i] - cum[j] >= m) return pts[j];
    }
    return i > 0 ? pts[0] : null;
  }

  GeoPoint? _pointAhead(List<GeoPoint> pts, List<double> cum, int i, double m) {
    for (var j = i + 1; j < pts.length; j++) {
      if (cum[j] - cum[i] >= m) return pts[j];
    }
    return i < pts.length - 1 ? pts.last : null;
  }

  /// Douglas-Peucker line simplification ([tol] metres).
  static List<GeoPoint> _simplify(List<GeoPoint> pts, double tol) {
    if (pts.length < 3) return pts;
    final keepIt = List<bool>.filled(pts.length, false);
    keepIt[0] = true;
    keepIt[pts.length - 1] = true;
    final stack = <(int, int)>[(0, pts.length - 1)];
    while (stack.isNotEmpty) {
      final (a, b) = stack.removeLast();
      var maxD = 0.0;
      var idx = -1;
      for (var i = a + 1; i < b; i++) {
        final d = _distToSegment(pts[i], pts[a], pts[b]);
        if (d > maxD) {
          maxD = d;
          idx = i;
        }
      }
      if (idx >= 0 && maxD > tol) {
        keepIt[idx] = true;
        stack.add((a, idx));
        stack.add((idx, b));
      }
    }
    return [for (var i = 0; i < pts.length; i++) if (keepIt[i]) pts[i]];
  }

  static double _distToSegment(GeoPoint p, GeoPoint a, GeoPoint b) {
    final cosLat = math.cos(p.lat * math.pi / 180);
    double x(GeoPoint g) => (g.lon - p.lon) * 111320 * cosLat;
    double y(GeoPoint g) => (g.lat - p.lat) * 111320;
    final ax = x(a), ay = y(a), bx = x(b), by = y(b);
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    final t = len2 == 0 ? 0.0 : (-(ax * dx + ay * dy) / len2).clamp(0.0, 1.0).toDouble();
    final px = ax + t * dx, py = ay + t * dy;
    return math.sqrt(px * px + py * py);
  }
}
