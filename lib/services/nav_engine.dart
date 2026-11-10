import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../utils/geo.dart';
import 'routing_service.dart';
import 'voice_service.dart';

/// Follows the driver along the route: next turn, distances, voice prompts,
/// arrival, and asking for a new route when the driver goes off route.
class NavEngine extends ChangeNotifier {
  NavEngine({required this.voice, required this.onOffRoute});

  final VoiceService voice;

  /// Called when the driver has left the route; should fetch a new one.
  final Future<void> Function(GeoPoint from, double? heading) onOffRoute;

  RouteResult? route;
  int _seg = 0;
  int nextIndex = 0;
  double progressM = 0;
  double distToNextM = 0;
  double remainingM = 0;
  double remainingS = 0;
  double speedKmh = 0;
  bool arrived = false;
  bool rerouting = false;
  GeoPoint? snapped;

  /// Live traffic: travel time with traffic ÷ normal travel time.
  double trafficFactor = 1.0;

  /// Route from where you are now to the end (for traffic checks).
  List<GeoPoint> remainingPath() {
    final r = route;
    if (r == null) return const [];
    final from = snapped;
    final rest = r.points.sublist((_seg + 1).clamp(0, r.points.length));
    return [if (from != null) from else r.points[_seg.clamp(0, r.points.length - 1)], ...rest];
  }
  double? heading;

  int _offCount = 0;
  DateTime _lastReroute = DateTime.fromMillisecondsSinceEpoch(0);
  final Set<String> _spoken = {};

  Maneuver? get nextManeuver {
    final r = route;
    if (r == null || nextIndex >= r.maneuvers.length) return null;
    return r.maneuvers[nextIndex];
  }

  void start(RouteResult r) {
    setRoute(r);
    voice.sayStarted();
  }

  void setRoute(RouteResult r) {
    route = r;
    _seg = 0;
    nextIndex = r.maneuvers.length > 1 ? 1 : 0; // skip the "start" maneuver
    progressM = 0;
    trafficFactor = 1.0;
    remainingM = r.totalM;
    remainingS = r.totalS;
    distToNextM = r.maneuvers.length > 1 ? r.cum[r.maneuvers[1].beginIndex] : r.totalM;
    arrived = false;
    rerouting = false;
    _offCount = 0;
    _spoken.clear();
    notifyListeners();
  }

  void stop() {
    route = null;
    voice.stop();
    notifyListeners();
  }

  void onPosition(GeoPoint p, double speedMs, double? headingDeg) {
    final r = route;
    if (r == null || arrived || r.points.length < 2) return;
    speedKmh = math.max(0.0, speedMs * 3.6);
    if (headingDeg != null && speedMs > 1.5) heading = headingDeg;

    // Search near the last known position first, then the whole route.
    var s = snapToLine(r.points, p,
        from: math.max(0, _seg - 5), to: math.min(r.points.length - 1, _seg + 400));
    if (s.offRouteM > 40) {
      final full = snapToLine(r.points, p);
      if (full.offRouteM < s.offRouteM) s = full;
    }

    if (s.offRouteM > 50) {
      _offCount++;
      if (_offCount >= 3 &&
          !rerouting &&
          DateTime.now().difference(_lastReroute).inSeconds > 15) {
        _lastReroute = DateTime.now();
        rerouting = true;
        notifyListeners();
        voice.sayRerouting();
        onOffRoute(p, heading).whenComplete(() {
          rerouting = false;
          notifyListeners();
        });
      }
      return;
    }
    _offCount = 0;

    _seg = s.segment;
    final segLen = r.cum[s.segment + 1] - r.cum[s.segment];
    progressM = r.cum[s.segment] + segLen * s.fraction;
    final a = r.points[s.segment], b = r.points[s.segment + 1];
    snapped = GeoPoint(a.lat + (b.lat - a.lat) * s.fraction, a.lon + (b.lon - a.lon) * s.fraction);
    if (heading == null || speedMs <= 1.5) heading = bearingDeg(a, b);

    remainingM = math.max(0.0, r.totalM - progressM);
    remainingS = (r.totalM > 0 ? r.totalS * remainingM / r.totalM : 0) * trafficFactor;

    while (nextIndex < r.maneuvers.length - 1 &&
        r.cum[r.maneuvers[nextIndex].beginIndex] <= progressM + 2) {
      nextIndex++;
    }
    final m = r.maneuvers[nextIndex];
    distToNextM = math.max(0.0, r.cum[math.min(m.beginIndex, r.cum.length - 1)] - progressM);

    if (remainingM < 30) {
      arrived = true;
      voice.sayNow(r.maneuvers.last);
      notifyListeners();
      return;
    }

    _maybeSpeak(m, distToNextM);
    notifyListeners();
  }

  void _maybeSpeak(Maneuver m, double d) {
    final double far, near;
    if (speedKmh > 80) {
      far = 1500;
      near = 500;
    } else if (speedKmh > 50) {
      far = 600;
      near = 200;
    } else {
      far = 300;
      near = 100;
    }
    final nowDist = math.max(25.0, speedKmh / 3.6 * 4);
    final key = '$nextIndex';

    if (d <= nowDist) {
      if (_spoken.add('$key-now')) voice.sayNow(m);
    } else if (d <= near) {
      if (_spoken.add('$key-near')) voice.sayAnnouncement(m, d);
    } else if (d <= far && d > near + 50) {
      if (_spoken.add('$key-far')) voice.sayAnnouncement(m, d);
    }
  }
}
