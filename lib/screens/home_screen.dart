import 'dart:async';
import 'dart:math' show Point;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../main.dart';
import '../services/nav_engine.dart';
import '../services/routing_service.dart';
import '../services/settings.dart';
import '../services/style_builder.dart';
import '../services/traffic_service.dart';
import '../services/voice_service.dart';
import '../utils/geo.dart';
import 'favourites_screen.dart';
import 'maps_screen.dart';
import 'places_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'zones_screen.dart';

enum Mode { browse, preview, driving }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final s = Services.i;
  MapLibreMapController? _map;
  BuiltStyle? _style;
  bool _styleNight = false;
  bool _styleBuilt3d = false;

  bool _hasLocation = false;
  StreamSubscription<Position>? _posSub;
  StreamSubscription? _wifiSub;
  Position? _pos;

  Mode _mode = Mode.browse;
  Place? _dest;
  RouteResult? _route;
  bool _loadingRoute = false;
  bool _is3d = false;
  bool _follow = true;
  Timer? _themeTimer;

  // Live traffic
  TrafficCheck? _traffic;
  List<Incident> _incidents = [];
  Timer? _trafficTimer;
  bool _checkingTraffic = false;
  bool _switching = false;

  // Retracing your trail
  bool _retracing = false;
  List<GeoPoint> _retracePath = const [];
  Timer? _trailTimer;

  // Speed limits along the current route: (distance from start, km/h).
  List<(double, int)> _limits = [];
  RouteResult? _limitsFor;

  // Auto 3D in towns
  bool _manual3d = false;
  DateTime _last3dSwitch = DateTime.fromMillisecondsSinceEpoch(0);
  final List<(DateTime, double)> _speedLog = [];
  bool _arrivedShown = false;

  late final NavEngine _nav = NavEngine(voice: s.voice, onOffRoute: _reroute);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nav.addListener(_onNav);
    s.settings.addListener(_onSettings);
    _styleNight = s.settings.isNight;
    _buildStyle();
    _startLocation();
    _themeTimer = Timer.periodic(const Duration(minutes: 5), (_) => _onSettings());
    // Redraw your trail as it grows.
    _trailTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (s.settings.showTrail) _drawRoute();
    });
    // Weekly map update check, and catch-up when Wi-Fi comes back.
    Future.delayed(const Duration(seconds: 4), _checkMapUpdates);
    _wifiSub = s.packs.watchWifi(() async {
      if (s.packs.pendingUpdate) await _checkMapUpdates();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel();
    _wifiSub?.cancel();
    _themeTimer?.cancel();
    _trafficTimer?.cancel();
    _trailTimer?.cancel();
    s.trail.save();
    _nav.removeListener(_onNav);
    s.settings.removeListener(_onSettings);
    WakelockPlus.disable();
    super.dispose();
  }

  // ---------------- Map style ----------------

  Future<void> _buildStyle() async {
    final want3d = _is3d;
    final built = await s.styles.build(
        night: _styleNight,
        show3d: want3d,
        trafficKey: s.settings.showTraffic ? s.settings.tomtomKey : null);
    if (!mounted) return;
    _styleBuilt3d = want3d;
    final changed = _style?.styleString != built.styleString;
    setState(() => _style = built);
    if (changed && _map != null) {
      try {
        await _map!.setStyle(built.styleString);
      } catch (_) {}
    }
  }

  void _onSettings() {
    final night = s.settings.isNight;
    if (night != _styleNight) {
      _styleNight = night;
      _buildStyle();
    }
    if (mounted) setState(() {});
  }

  Future<void> _onStyleLoaded() async {
    await _drawRoute();
    await _apply3dBuildings();
  }

  Future<void> _apply3dBuildings() async {
    final ids = _style?.buildingLayerIds ?? const [];
    for (final id in ids) {
      try {
        await _map?.setLayerVisibility(id, _is3d);
      } catch (_) {
        // If layer toggles fail, rebuild the style with buildings on/off,
        // but only if the current style was built the other way.
        if (_styleBuilt3d != _is3d) await _buildStyle();
        return;
      }
    }
  }

  Future<void> _checkMapUpdates() async {
    final msg = await s.packs.weeklyCheck(onUpdated: _buildStyle);
    if (msg != null && mounted) _toast(msg);
  }

  // ---------------- Location ----------------

  Future<void> _startLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _toast('Please switch on Location (GPS).');
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      _toast('SafeRoute needs your location to navigate.');
      return;
    }
    setState(() => _hasLocation = true);
    try {
      final first = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high))
          .timeout(const Duration(seconds: 15));
      _onPosition(first, initial: true);
    } catch (_) {}
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3,
      ),
    ).listen(_onPosition);
  }

  GeoPoint? get _here => _pos == null ? null : GeoPoint(_pos!.latitude, _pos!.longitude);

  void _onPosition(Position p, {bool initial = false}) {
    _pos = p;
    if (s.settings.recordTrail) s.trail.add(p.latitude, p.longitude, p.speed, p.accuracy);
    if (initial && _mode == Mode.browse) {
      _map?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(p.latitude, p.longitude), 14));
    }
    if (_mode == Mode.driving) {
      _nav.onPosition(GeoPoint(p.latitude, p.longitude), p.speed,
          p.heading >= 0 ? p.heading : null);
      _maybeAuto3d();
      if (_follow) _followCamera();
    }
  }

  void _followCamera() {
    final target = _nav.offRoute ? (_here ?? _nav.snapped) : (_nav.snapped ?? _here);
    if (target == null || _map == null) return;
    _map!.animateCamera(
      CameraUpdate.newCameraPosition(CameraPosition(
        target: LatLng(target.lat, target.lon),
        zoom: _is3d ? 17.2 : 16.0,
        bearing: _nav.heading ?? 0,
        tilt: _is3d ? 60 : 0,
      )),
      duration: const Duration(milliseconds: 900),
    );
  }

  // ---------------- Routing ----------------

  Future<void> _pickDestination() async {
    final place = await Navigator.push<Place>(
      context,
      MaterialPageRoute(builder: (_) => SearchScreen(near: _here)),
    );
    if (place != null) _routeTo(place);
  }

  Future<void> _routeTo(Place place) async {
    final from = _here;
    if (from == null) {
      _toast('Waiting for your GPS position…');
      return;
    }
    s.settings.addRecent(place);
    setState(() {
      _dest = place;
      _loadingRoute = true;
      _mode = Mode.preview;
    });
    try {
      final r = await s.routing.route(from, place.point,
          headingDeg: (_pos?.heading ?? -1) >= 0 ? _pos!.heading : null);
      if (!mounted) return;
      setState(() {
        _route = r;
        _traffic = null;
        _incidents = [];
      });
      await _drawRoute();
      _fitRoute(r);
      _previewTraffic(r);
      _loadLanes(r);
    } catch (e) {
      _toast(e.toString());
      _cancel();
    } finally {
      if (mounted) setState(() => _loadingRoute = false);
    }
  }

  Future<void> _reroute(GeoPoint from, double? heading) async {
    final dest = _dest;
    if (dest == null) return;
    if (_retracing) {
      _rejoinTrail(from);
      return;
    }
    try {
      RouteResult r;
      try {
        r = await s.routing.route(from, dest.point, headingDeg: heading);
      } catch (_) {
        // Try once more without the driving direction (it can confuse the
        // router on big interchanges and when GPS direction is off).
        r = await s.routing.route(from, dest.point);
      }
      if (!mounted || _mode != Mode.driving) return;
      _route = r;
      _nav.setRoute(r);
      await _drawRoute();
      _drivingTraffic();
      _loadLanes(r);
    } catch (e) {
      // Keep the old route; another attempt follows in 10 seconds.
      _nav.rerouteError = e.toString().replaceFirst('Exception: ', '');
      if (mounted) setState(() {});
    }
  }

  // ---------------- Live traffic ----------------

  Future<void> _previewTraffic(RouteResult r) async {
    if (!s.settings.hasTraffic) return;
    setState(() => _checkingTraffic = true);
    final results = await Future.wait<Object?>([
      s.traffic.check(r.points),
      _loadIncidents(r.points),
    ]);
    if (!mounted || _route != r) return;
    setState(() {
      _traffic = results[0] as TrafficCheck?;
      _checkingTraffic = false;
    });
    _setLimits(_traffic, r, 0);
    await _drawRoute();
  }

  Future<void> _loadIncidents(List<GeoPoint> pts) async {
    if (pts.isEmpty) return;
    double w = 180, s0 = 90, e = -180, n = -90;
    for (final p in pts) {
      if (p.lon < w) w = p.lon;
      if (p.lon > e) e = p.lon;
      if (p.lat < s0) s0 = p.lat;
      if (p.lat > n) n = p.lat;
    }
    const pad = 0.02;
    final list = await s.traffic.incidents(w - pad, s0 - pad, e + pad, n + pad, pts.first);
    // Keep only incidents on (or right next to) the route.
    _incidents = list.where((i) => snapToLine(pts, i.point).offRouteM < 60).toList();
  }

  /// Use TomTom's faster route (turned into turn-by-turn directions).
  Future<bool> _useFaster({required bool driving}) async {
    final alt = _traffic?.faster;
    if (alt == null || _switching) return false;
    _switching = true;
    try {
      final heading = driving ? _nav.heading : ((_pos?.heading ?? -1) >= 0 ? _pos!.heading : null);
      final path = driving ? [_nav.snapped ?? _here ?? alt.points.first, ...alt.points.skip(1)] : alt.points;
      final r = await s.routing.routeAlong(path, headingDeg: heading);
      if (!mounted || r == null) return false;
      if (driving && _mode != Mode.driving) return false;
      final saved = _traffic!.savingS;
      setState(() {
        _route = r;
        _traffic = TrafficCheck(alt.timeS, 0, null);
      });
      _loadLanes(r);
      if (driving) {
        _nav.setRoute(r);
        _nav.trafficFactor = r.totalS > 0 ? alt.timeS / r.totalS : 1.0;
        s.voice.sayFaster();
        _toast('Faster route: saves ${formatDuration(saved)}.');
        // Fetch speed limits for the new route.
        Future.delayed(const Duration(seconds: 3), _drivingTraffic);
      }
      await _drawRoute();
      return true;
    } finally {
      _switching = false;
    }
  }

  /// While driving: check traffic every 4 minutes.
  void _startTrafficTimer() {
    _trafficTimer?.cancel();
    if (!s.settings.hasTraffic) return;
    _trafficTimer = Timer.periodic(const Duration(minutes: 4), (_) => _drivingTraffic());
  }

  Future<void> _drivingTraffic() async {
    if (_retracing) return; // never swap your trail for a "faster" road
    if (!s.settings.hasTraffic || _mode != Mode.driving || _nav.remainingM < 2000) return;
    final path = _nav.remainingPath();
    final results = await Future.wait<Object?>([
      s.traffic.check(path),
      _loadIncidents(path),
    ]);
    if (!mounted || _mode != Mode.driving) return;
    final check = results[0] as TrafficCheck?;
    if (check != null) {
      final normal = _nav.route == null || _nav.route!.totalM <= 0
          ? 0.0
          : _nav.route!.totalS * _nav.remainingM / _nav.route!.totalM;
      if (normal > 0) _nav.trafficFactor = (check.timeS / normal).clamp(0.5, 4.0);
      setState(() => _traffic = check);
      if (_nav.route != null) _setLimits(check, _nav.route!, _nav.progressM);
      if (s.settings.autoFaster && check.faster != null && check.savingS >= 180) {
        await _useFaster(driving: true);
      }
    }
    await _drawRoute();
  }

  Future<void> _drawRoute() async {
    final m = _map;
    if (m == null) return;
    try {
      await m.clearLines();
      await m.clearCircles();
      await m.clearFills();
    } catch (_) {}
    // Your avoid zones, shaded on the map.
    if (s.settings.avoidZones) {
      try {
        for (final z in s.settings.zones) {
          if (!z.enabled || z.points.length < 3) continue;
          final ring = [...z.points, z.points.first].map((p) => LatLng(p.lat, p.lon)).toList();
          final color = z.nightOnly ? zoneAmber : zoneRed;
          await m.addFill(FillOptions(geometry: [ring], fillColor: color, fillOpacity: 0.18));
          await m.addLine(LineOptions(geometry: ring, lineColor: color, lineWidth: 2, lineOpacity: 0.8));
        }
      } catch (_) {}
    }
    // Your trail (last hour) in orange.
    if (s.settings.showTrail && !_retracing) {
      final trail = s.trail.recent(const Duration(hours: 1));
      if (trail.length >= 2) {
        try {
          await m.addLine(LineOptions(
            geometry: trail.map((p) => LatLng(p.lat, p.lon)).toList(),
            lineColor: '#FF7043',
            lineWidth: 4,
            lineOpacity: 0.75,
          ));
        } catch (_) {}
      }
    }
    final r = _route;
    if (r == null || _mode == Mode.browse) return;
    final geom = r.points.map((p) => LatLng(p.lat, p.lon)).toList();
    try {
      await m.addLine(LineOptions(
          geometry: geom, lineColor: _retracing ? '#BF360C' : '#0D47A1', lineWidth: 11, lineOpacity: 0.9));
      await m.addLine(LineOptions(
          geometry: geom, lineColor: _retracing ? '#FF7043' : Brand.routeBlue, lineWidth: 7, lineOpacity: 1));
      // Stretches that go through a zone are drawn red.
      for (final h in r.hits) {
        for (final st in h.stretches) {
          if (st.length < 2) continue;
          await m.addLine(LineOptions(
            geometry: st.map((p) => LatLng(p.lat, p.lon)).toList(),
            lineColor: zoneRed,
            lineWidth: 9,
          ));
        }
      }
      final d = r.points.last;
      await m.addCircle(CircleOptions(
        geometry: LatLng(d.lat, d.lon),
        circleRadius: 9,
        circleColor: '#E85D4A',
        circleStrokeWidth: 3,
        circleStrokeColor: '#FFFFFF',
      ));
      for (final i in _incidents) {
        await m.addCircle(CircleOptions(
          geometry: LatLng(i.point.lat, i.point.lon),
          circleRadius: 8,
          circleColor: i.color,
          circleStrokeWidth: 2,
          circleStrokeColor: '#FFFFFF',
        ));
      }
    } catch (_) {}
  }

  void _fitRoute(RouteResult r) {
    double minLat = 90, maxLat = -90, minLon = 180, maxLon = -180;
    for (final p in r.points) {
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
      if (p.lon < minLon) minLon = p.lon;
      if (p.lon > maxLon) maxLon = p.lon;
    }
    _map?.animateCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(southwest: LatLng(minLat, minLon), northeast: LatLng(maxLat, maxLon)),
      left: 60, right: 60, top: 140, bottom: 300,
    ));
  }

  void _startDriving() {
    final r = _route;
    if (r == null) return;
    setState(() {
      _mode = Mode.driving;
      _follow = true;
      _arrivedShown = false;
    });
    if (s.settings.keepScreenOn) WakelockPlus.enable();
    _manual3d = false;
    _speedLog.clear();
    _nav.start(r);
    final t0 = _traffic;
    if (t0 != null && r.totalS > 0) _nav.trafficFactor = (t0.timeS / r.totalS).clamp(0.5, 4.0);
    if (_pos != null) _onPosition(_pos!);
    _followCamera();
    _startTrafficTimer();
    // No speed limits yet for this route: fetch them shortly.
    if (s.settings.hasTraffic && !identical(_limitsFor, r)) {
      Future.delayed(const Duration(seconds: 5), _drivingTraffic);
    }
  }

  void _cancel() {
    _retracing = false;
    _retracePath = const [];
    _trafficTimer?.cancel();
    _limits = [];
    _limitsFor = null;
    _traffic = null;
    _incidents = [];
    _nav.stop();
    WakelockPlus.disable();
    setState(() {
      _mode = Mode.browse;
      _route = null;
      _dest = null;
    });
    _drawRoute();
    _map?.animateCamera(CameraUpdate.tiltTo(0));
  }

  /// Places TomTom's speed-limit changes along [route].
  void _setLimits(TrafficCheck? check, RouteResult route, double fromM) {
    if (check == null || check.limits.isEmpty) return;
    final out = <(double, int)>[];
    final startSeg = route.points.isEmpty
        ? 0
        : snapToLine(route.points, route.points.first).segment; // 0
    for (final l in check.limits) {
      final sn = snapToLine(route.points, l.start, from: startSeg);
      if (sn.offRouteM > 40) continue;
      final segLen = route.cum[sn.segment + 1] - route.cum[sn.segment];
      final along = route.cum[sn.segment] + segLen * sn.fraction;
      if (along + 50 < fromM && out.isNotEmpty) continue;
      out.add((along, l.kmh));
    }
    out.sort((a, b) => a.$1.compareTo(b.$1));
    _limits = out;
    _limitsFor = route;
  }

  /// Speed limit where you are now, if known.
  int? get _currentLimit {
    if (_limits.isEmpty || !identical(_limitsFor, _nav.route)) return null;
    int? kmh;
    for (final l in _limits) {
      if (l.$1 <= _nav.progressM + 10) {
        kmh = l.$2;
      } else {
        break;
      }
    }
    return kmh;
  }

  /// Auto 3D: on in towns (limit 60 or less, or slow driving), off on open roads.
  void _maybeAuto3d() {
    if (!s.settings.auto3d || _manual3d || _mode != Mode.driving) return;
    final now = DateTime.now();
    _speedLog.add((now, _nav.speedKmh));
    _speedLog.removeWhere((e) => now.difference(e.$1).inSeconds > 45);
    if (now.difference(_last3dSwitch).inSeconds < 30) return;
    bool? town;
    final lim = _currentLimit;
    if (lim != null) {
      if (lim <= 60) town = true;
      if (lim >= 80) town = false;
    } else if (_speedLog.length > 5 && now.difference(_speedLog.first.$1).inSeconds >= 30) {
      final avg = _speedLog.fold<double>(0, (a, e) => a + e.$2) / _speedLog.length;
      if (avg < 45) town = true;
      if (avg > 75) town = false;
    }
    if (town == null || town == _is3d) return;
    _last3dSwitch = now;
    setState(() => _is3d = town!);
    _apply3dBuildings();
  }

  Future<void> _loadLanes(RouteResult r) async {
    final lanes = await s.routing.fetchLanes(r);
    if (!mounted) return;
    r.lanes = lanes;
    setState(() {});
  }

  /// Lanes for the next junction ahead that has lane markings.
  LanePoint? _nextLanes() {
    final r = _nav.route;
    if (r == null || r.lanes.isEmpty || _nav.offRoute) return null;
    final window = _nav.speedKmh > 70 ? 1500.0 : 500.0;
    for (final lp in r.lanes) {
      final ahead = lp.alongM - _nav.progressM;
      if (ahead < -10) continue;
      if (ahead > window) return null;
      return lp;
    }
    return null;
  }

  static IconData _laneIcon(String arrow) {
    switch (arrow) {
      case 'slight right':
        return Icons.turn_slight_right;
      case 'right':
        return Icons.turn_right;
      case 'sharp right':
        return Icons.turn_sharp_right;
      case 'slight left':
        return Icons.turn_slight_left;
      case 'left':
        return Icons.turn_left;
      case 'sharp left':
        return Icons.turn_sharp_left;
      case 'uturn':
        return Icons.u_turn_right;
      default:
        return Icons.straight;
    }
  }

  Widget _laneRow(LanePoint lp) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final lane in lp.lanes)
              Container(
                width: 44,
                height: 50,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  color: lane.good ? Colors.white : Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final a in lane.arrows.take(2))
                      Icon(_laneIcon(a),
                          size: lane.arrows.length > 1 ? 20 : 30,
                          color: lane.good ? Brand.tealDark : Colors.white54),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// "Accident ahead · 1.2 km" for the next incident within 5 km.
  String? _nextIncidentText() {
    final r = _nav.route;
    if (r == null || _incidents.isEmpty) return null;
    double? best;
    Incident? which;
    for (final i in _incidents) {
      final sn = snapToLine(r.points, i.point);
      if (sn.offRouteM > 60) continue;
      final segLen = r.cum[sn.segment + 1] - r.cum[sn.segment];
      final along = r.cum[sn.segment] + segLen * sn.fraction - _nav.progressM;
      if (along > 0 && along < 5000 && (best == null || along < best)) {
        best = along;
        which = i;
      }
    }
    if (which == null) return null;
    return '${which.label} ahead · ${formatDistance(best!)}';
  }

  void _onNav() {
    if (!mounted) return;
    setState(() {});
    if (_nav.arrived && !_arrivedShown) {
      _arrivedShown = true;
      showDialog(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('You have arrived'),
          content: Text(_dest?.name ?? ''),
          actions: [
            FilledButton(
                onPressed: () {
                  Navigator.pop(c);
                  _cancel();
                },
                child: const Text('Done')),
          ],
        ),
      );
    }
  }

  Future<void> _toggle3d() async {
    if (_mode == Mode.driving) _manual3d = true; // you chose: no auto switching this trip
    setState(() => _is3d = !_is3d);
    await _apply3dBuildings();
    if (_mode == Mode.driving && _follow) {
      _followCamera();
    } else {
      _map?.animateCamera(CameraUpdate.tiltTo(_is3d ? 60 : 0));
    }
  }

  void _shareEta() {
    final dest = _dest;
    final secs = _mode == Mode.driving ? _nav.remainingS : (_route?.totalS ?? 0);
    if (dest == null) return;
    final eta = DateTime.now().add(Duration(seconds: secs.round()));
    final hh = eta.hour.toString().padLeft(2, '0');
    final mm = eta.minute.toString().padLeft(2, '0');
    final link = 'https://www.google.com/maps/search/?api=1&query=${dest.lat},${dest.lon}';
    Share.share("I'm on my way to ${dest.name}. ETA $hh:$mm (${formatDuration(secs)}).\n$link");
  }

  Future<void> _setFavourite(bool isHome) async {
    final place = await Navigator.push<Place>(
      context,
      MaterialPageRoute(
          builder: (_) => SearchScreen(near: _here, title: isHome ? 'Set Home' : 'Set Work')),
    );
    if (place == null) return;
    s.settings.update((st) {
      final p = Place(isHome ? 'Home' : 'Work', place.address.isEmpty ? place.name : place.address,
          place.lat, place.lon);
      if (isHome) {
        st.home = p;
      } else {
        st.work = p;
      }
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final style = _style;
    return Scaffold(
      body: Stack(
        children: [
          if (style == null)
            const Center(child: CircularProgressIndicator())
          else
            Listener(
              onPointerDown: (_) {
                if (_mode == Mode.driving && _follow) setState(() => _follow = false);
              },
              child: MapLibreMap(
                styleString: style.styleString,
                initialCameraPosition: CameraPosition(
                  target: LatLng(
                    _pos?.latitude ?? -26.2041,
                    _pos?.longitude ?? 28.0473,
                  ),
                  zoom: _pos == null ? 10 : 14,
                ),
                myLocationEnabled: _hasLocation,
                myLocationRenderMode: _hasLocation
                    ? MyLocationRenderMode.gps
                    : MyLocationRenderMode.normal,
                // Zones underneath, route lines and dots on top.
                annotationOrder: const [
                  AnnotationType.fill,
                  AnnotationType.line,
                  AnnotationType.circle,
                  AnnotationType.symbol,
                ],
                compassEnabled: false,
                attributionButtonPosition: AttributionButtonPosition.bottomLeft,
                onMapCreated: (c) => _map = c,
                onStyleLoadedCallback: _onStyleLoaded,
                onMapLongClick: (Point<double> point, LatLng latLng) {
                  if (_mode == Mode.driving) return;
                  _routeTo(Place('Dropped pin',
                      '${latLng.latitude.toStringAsFixed(5)}, ${latLng.longitude.toStringAsFixed(5)}',
                      latLng.latitude, latLng.longitude));
                },
              ),
            ),
          if (_mode == Mode.driving) ..._drivingOverlay(context) else ..._browseOverlay(context),
        ],
      ),
    );
  }

  Widget _roundButton(IconData icon, VoidCallback onTap, {String? tooltip, Color? color}) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: color ?? cs.surface,
      shape: const CircleBorder(),
      elevation: 4,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Icon(icon, size: 28, semanticLabel: tooltip),
        ),
      ),
    );
  }

  Widget _text3d(VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: _is3d ? cs.primary : cs.surface,
      shape: const CircleBorder(),
      elevation: 4,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 56,
          height: 56,
          child: Center(
            child: Text(_is3d ? '3D' : '2D',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: _is3d ? cs.onPrimary : cs.onSurface)),
          ),
        ),
      ),
    );
  }

  List<Widget> _browseOverlay(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final st = s.settings;
    final offline = _style?.offline ?? false;
    return [
      // Top buttons
      Positioned(
        top: MediaQuery.of(context).padding.top + 12,
        left: 12,
        right: 12,
        child: Row(
          children: [
            _roundButton(Icons.settings, () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
              _buildStyle();
            }, tooltip: 'Settings'),
            const SizedBox(width: 10),
            _roundButton(Icons.shield, _openZones,
                tooltip: 'Safety avoid zones',
                color: s.settings.avoidZones && s.settings.zones.any((z) => z.enabled)
                    ? const Color(0xFFE53935)
                    : null),
            const Spacer(),
            if (!offline)
              Expanded(
                flex: 6,
                child: Material(
                  color: Brand.amber,
                  borderRadius: BorderRadius.circular(24),
                  elevation: 4,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: _openMaps,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Text('Online map · Tap to download your province',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.black, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
              ),
            const Spacer(),
            _roundButton(Icons.download_for_offline, _openMaps, tooltip: 'Offline maps'),
          ],
        ),
      ),
      // Right-side buttons
      Positioned(
        right: 12,
        bottom: _mode == Mode.preview ? 250 : 200,
        child: Column(
          children: [
            _roundButton(Icons.history, _showRetrace, tooltip: 'Retrace my trail', color: const Color(0xFFFF7043)),
            const SizedBox(height: 12),
            _text3d(_toggle3d),
            const SizedBox(height: 12),
            _roundButton(Icons.my_location, () {
              final h = _here;
              if (h != null) {
                _map?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(h.lat, h.lon), 15));
              }
            }, tooltip: 'My location'),
          ],
        ),
      ),
      // Bottom card
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: Container(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: const [BoxShadow(blurRadius: 12, color: Colors.black26)],
          ),
          padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).padding.bottom + 16),
          child: _mode == Mode.preview ? _previewCard(cs) : _whereTo(cs, st),
        ),
      ),
    ];
  }

  Future<void> _openMaps() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const MapsScreen()));
    _buildStyle();
  }

  Widget _whereTo(ColorScheme cs, Settings st) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: _pickDestination,
          borderRadius: BorderRadius.circular(28),
          child: Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Row(children: [
              Icon(Icons.search, color: cs.primary, size: 28),
              const SizedBox(width: 12),
              Text('Where to?',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant)),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _favButton(Icons.home, 'Home', st.home, true)),
          const SizedBox(width: 8),
          Expanded(child: _favButton(Icons.work, 'Work', st.work, false)),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 52),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
              ),
              icon: const Icon(Icons.star),
              label: const Text('Saved', style: TextStyle(fontSize: 16)),
              onPressed: _openFavourites,
            ),
          ),
        ]),
      ],
    );
  }

  Widget _favButton(IconData icon, String label, Place? place, bool isHome) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 52),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      ),
      icon: Icon(place == null ? Icons.add : icon),
      label: Text(label, style: const TextStyle(fontSize: 16)),
      onPressed: () => place == null ? _setFavourite(isHome) : _routeTo(place),
      onLongPress: () => _setFavourite(isHome),
    );
  }

  /// While driving: find a place along your route and go there instead.
  Future<void> _findWhileDriving() async {
    final here = _here;
    if (here == null) return;
    final place = await Navigator.push<Place>(
      context,
      MaterialPageRoute(builder: (_) => PlacesScreen(here: here, route: _nav.remainingPath())),
    );
    if (place == null || !mounted) return;
    _nav.stop();
    _trafficTimer?.cancel();
    await _routeTo(place);
    if (mounted && _route != null && _mode == Mode.preview) _startDriving();
  }

  // ---------------- Retrace your trail ----------------

  String _ago(DateTime t) {
    final m = DateTime.now().difference(t).inMinutes;
    if (m < 60) return '$m min ago';
    return '${m ~/ 60} h ${m % 60} min ago';
  }

  Future<void> _showRetrace() async {
    final here = _here;
    final trail = s.trail;
    if (here == null || trail.points.length < 3) {
      _toast(s.settings.recordTrail
          ? 'No trail yet. Your trail is recorded while the app is open and you are driving.'
          : 'Trail recording is off. Turn it on in Settings.');
      return;
    }
    final start = trail.tripStartIndex();
    final options = <(String, String, int)>[];
    final startPath = trail.pathBack(here, start);
    options.add((
      'Back to where this trip started',
      '${formatDistance(trail.lengthM(startPath))} · ${_ago(trail.points[start].time)}',
      start
    ));
    for (final mins in [5, 10, 20, 30]) {
      final i = trail.indexAgo(Duration(minutes: mins));
      if (i <= start || i >= trail.points.length - 2) continue;
      final path = trail.pathBack(here, i);
      options.add(('Back $mins minutes', formatDistance(trail.lengthM(path)), i));
    }
    final chosen = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text('Get out the way you came in',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Follows the exact streets you drove, in reverse. Watch for one-way streets.'),
          ),
          for (final o in options)
            ListTile(
              leading: const Icon(Icons.history, color: Color(0xFFFF7043)),
              title: Text(o.$1, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(o.$2),
              onTap: () => Navigator.pop(c, o.$3),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (chosen == null || !mounted) return;
    final path = trail.pathBack(here, chosen);
    if (path.length < 2 || trail.lengthM(path) < 60) {
      _toast('You are already there.');
      return;
    }
    _startRetrace(path);
  }

  void _startRetrace(List<GeoPoint> path) {
    if (_mode == Mode.driving) _nav.stop();
    final r = s.trail.routeFromPath(path);
    final end = path.last;
    setState(() {
      _retracing = true;
      _retracePath = path;
      _dest = Place('Back along your trail', '', end.lat, end.lon);
      _route = r;
      _traffic = null;
      _incidents = [];
      _mode = Mode.preview;
    });
    _startDriving();
    _drawRoute();
  }

  /// Off the trail while retracing: lead you back onto it, then follow it.
  void _rejoinTrail(GeoPoint from) {
    final path = _retracePath;
    if (path.length < 2) return;
    final sn = snapToLine(path, from);
    final rest = path.sublist((sn.segment + 1).clamp(0, path.length - 1));
    final newPath = [from, ...rest];
    if (newPath.length < 2) return;
    final r = s.trail.routeFromPath(newPath);
    _route = r;
    _nav.setRoute(r);
    if (sn.offRouteM > 300) {
      _nav.rerouteError = 'You are ${formatDistance(sn.offRouteM)} from your trail. Head back to the orange line.';
    }
    _drawRoute();
    if (mounted) setState(() {});
  }

  Future<void> _openZones() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ZonesScreen(start: _here)));
    if (!mounted) return;
    setState(() {});
    // Zones may have changed: work out the route again.
    if (_mode == Mode.preview && _dest != null) {
      _routeTo(_dest!);
    } else {
      _drawRoute();
    }
  }

  Future<void> _openFavourites() async {
    final place = await Navigator.push<Place>(
      context,
      MaterialPageRoute(builder: (_) => FavouritesScreen(near: _here)),
    );
    if (place != null) _routeTo(place);
  }

  /// Star button: save the destination under a name, or remove it.
  Future<void> _toggleFavourite() async {
    final dest = _dest;
    if (dest == null) return;
    final st = s.settings;
    final existing = st.favouriteAt(dest);
    if (existing != null) {
      st.removeFavourite(existing);
      _toast('Removed "${existing.name}" from Saved.');
      setState(() {});
      return;
    }
    final name = await askPlaceName(context, dest.name == 'Dropped pin' ? '' : dest.name);
    if (name == null) return;
    final saved = Place(name, dest.address.isEmpty ? dest.name : dest.address, dest.lat, dest.lon);
    st.saveFavourite(saved);
    setState(() => _dest = saved);
    _toast('Saved "$name".');
  }

  Widget _zoneWarning(RouteResult r) {
    final lines = <String>[
      ...r.notes,
      for (final h in r.hits) 'Goes through "${h.zone.name}" for ${formatDistance(h.metres)}.',
    ];
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFE53935).withValues(alpha: 0.15),
        border: Border.all(color: const Color(0xFFE53935), width: 2),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.warning_amber, color: Color(0xFFE53935), size: 30),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.passesZones ? 'No route avoids your zones' : 'Safety note',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 4),
            ...lines.map((l) => Text(l)),
            if (r.passesZones) const Text('The red part of the route is inside the zone.'),
          ]),
        ),
      ]),
    );
  }

  Widget _previewCard(ColorScheme cs) {
    final r = _route;
    final isFav = _dest != null && s.settings.favouriteAt(_dest!) != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
            child: Text(_dest?.name ?? '',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          ),
          IconButton(
            iconSize: 32,
            tooltip: isFav ? 'Remove from Saved' : 'Save this place',
            onPressed: _toggleFavourite,
            icon: Icon(isFav ? Icons.star : Icons.star_border,
                color: isFav ? Brand.amber : cs.onSurfaceVariant),
          ),
        ]),
        if ((_dest?.address ?? '').isNotEmpty)
          Text(_dest!.address, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.onSurfaceVariant)),
        const SizedBox(height: 10),
        if (_loadingRoute)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (r != null) ...[
          Text('${formatDuration(_traffic?.timeS ?? r.totalS)} · ${formatDistance(r.totalM)}',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: cs.primary)),
          if (r.plannedOffline)
            Row(children: [
              Icon(Icons.offline_bolt, size: 18, color: cs.primary),
              const SizedBox(width: 4),
              Text('Planned on your phone (no data needed)',
                  style: TextStyle(color: cs.onSurfaceVariant)),
            ]),
          if (_checkingTraffic)
            Text('Checking live traffic…', style: TextStyle(color: cs.onSurfaceVariant))
          else if (_traffic != null)
            Text(
              _traffic!.delayS >= 60
                  ? 'Includes ${formatDuration(_traffic!.delayS)} of traffic delay'
                  : 'Traffic is light',
              style: TextStyle(
                  color: _traffic!.delayS >= 300 ? const Color(0xFFD32F2F) : cs.onSurfaceVariant,
                  fontWeight: FontWeight.w600),
            )
          else if (!s.settings.hasTraffic)
            Text('No live traffic: add your TomTom key in Settings',
                style: TextStyle(color: cs.onSurfaceVariant)),
          if (_incidents.isNotEmpty)
            Text(
              '${_incidents.length} incident(s) on this route: '
              '${_incidents.map((i) => i.label).toSet().join(', ')}',
              style: const TextStyle(color: Color(0xFFD32F2F), fontWeight: FontWeight.w600),
            ),
          if (_traffic?.faster != null && _traffic!.savingS >= 60)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton.tonalIcon(
                onPressed: () => _useFaster(driving: false),
                icon: const Icon(Icons.bolt),
                label: Text('Faster route: saves ${formatDuration(_traffic!.savingS)}'),
              ),
            ),
        ],
        if (r != null && !_loadingRoute && (r.passesZones || r.notes.isNotEmpty))
          _zoneWarning(r)
        else if (r != null && !_loadingRoute && s.settings.activeZones().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              const Icon(Icons.verified_user, color: Color(0xFF43A047), size: 20),
              const SizedBox(width: 6),
              Text('Avoids all your zones', style: TextStyle(color: cs.onSurfaceVariant)),
            ]),
          ),
        const SizedBox(height: 14),
        Row(children: [
          IconButton.filledTonal(
              iconSize: 28, onPressed: _cancel, icon: const Icon(Icons.close), tooltip: 'Cancel'),
          const SizedBox(width: 8),
          IconButton.filledTonal(
              iconSize: 28, onPressed: r == null ? null : _shareEta,
              icon: const Icon(Icons.share), tooltip: 'Share ETA'),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              style: r != null && r.passesZones
                  ? FilledButton.styleFrom(backgroundColor: const Color(0xFFE53935))
                  : null,
              onPressed: r == null ? null : _startDriving,
              icon: Icon(r != null && r.passesZones ? Icons.warning_amber : Icons.navigation),
              label: Text(r != null && r.passesZones ? 'Drive anyway' : 'Go'),
            ),
          ),
        ]),
      ],
    );
  }

  List<Widget> _drivingOverlay(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final m = _nav.nextManeuver;
    final top = MediaQuery.of(context).padding.top;
    final eta = DateTime.now().add(Duration(seconds: _nav.remainingS.round()));
    final etaText =
        '${eta.hour.toString().padLeft(2, '0')}:${eta.minute.toString().padLeft(2, '0')}';
    final actionText = m == null ? '' : s.voice.action(m);
    return [
      // Next turn banner
      Positioned(
        top: top + 8,
        left: 10,
        right: 10,
        child: Material(
          color: Brand.teal,
          borderRadius: BorderRadius.circular(20),
          elevation: 6,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(_nav.offRoute ? Icons.wrong_location : VoiceService.iconFor(m), color: Colors.white, size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_nav.offRoute ? (s.voice.lang == 'af' ? 'Van roete af' : 'Off route') : formatDistance(_nav.distToNextM),
                      style: const TextStyle(
                          color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800)),
                  Text(
                    m == null || m.street.isEmpty
                        ? (actionText.isEmpty ? '' : actionText[0].toUpperCase() + actionText.substring(1)) +
                            (_retracing ? (s.voice.lang == 'af' ? ' · terug op jou spoor' : ' · retracing your trail') : '')
                        : m.street,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ]),
              ),
            ]),
            if (_nextLanes() != null) _laneRow(_nextLanes()!),
            ]),
          ),
        ),
      ),
      if (!_nav.rerouting && !_nav.offRoute && (_nav.route?.passesZones ?? false))
        Positioned(
          top: top + (_nextLanes() != null ? 180 : 120),
          left: 0,
          right: 0,
          child: Center(
            child: Chip(
              backgroundColor: const Color(0xFFE53935),
              avatar: const Icon(Icons.warning_amber, color: Colors.white, size: 18),
              label: Text('Route passes "${_nav.route!.hits.first.zone.name}"',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          ),
        ),
      if (_nextIncidentText() != null)
        Positioned(
          top: top + (_nextLanes() != null ? 230 : 170),
          left: 0,
          right: 0,
          child: Center(
            child: Chip(
              backgroundColor: const Color(0xFFFB8C00),
              avatar: const Icon(Icons.report, color: Colors.white, size: 18),
              label: Text(_nextIncidentText()!,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          ),
        ),
      if (!_nav.rerouting && _nav.offRoute && _nav.rerouteError != null)
        Positioned(
          top: top + (_nextLanes() != null ? 180 : 120),
          left: 16,
          right: 16,
          child: Center(
            child: Material(
              color: const Color(0xFFD32F2F),
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Text(
                  "Can't find a new route yet (trying again): ${_nav.rerouteError}",
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
        ),
      if (_nav.rerouting)
        Positioned(
          top: top + (_nextLanes() != null ? 180 : 120),
          left: 0,
          right: 0,
          child: Center(
            child: Chip(
              avatar: const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              label: Text(s.voice.lang == 'af' ? 'Herbereken…' : 'Recalculating…'),
            ),
          ),
        ),
      // Speed limit sign and your speed (red when you're over the limit)
      Positioned(
        left: 12,
        bottom: 150 + MediaQuery.of(context).padding.bottom,
        child: Builder(builder: (context) {
          final limit = _currentLimit;
          final over = limit != null && _nav.speedKmh > limit + 5;
          return Column(mainAxisSize: MainAxisSize.min, children: [
            if (limit != null)
              Container(
                width: 64,
                height: 64,
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFD32F2F), width: 7),
                  boxShadow: const [BoxShadow(blurRadius: 8, color: Colors.black26)],
                ),
                child: Center(
                  child: Text('$limit',
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w900, color: Colors.black)),
                ),
              ),
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: over ? const Color(0xFFD32F2F) : cs.surface,
                shape: BoxShape.circle,
                boxShadow: const [BoxShadow(blurRadius: 8, color: Colors.black26)],
              ),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(_nav.speedKmh.round().toString(),
                    style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: over ? Colors.white : null)),
                Text('km/h', style: TextStyle(fontSize: 11, color: over ? Colors.white : null)),
              ]),
            ),
          ]);
        }),
      ),
      // Right buttons
      Positioned(
        right: 12,
        bottom: 150 + MediaQuery.of(context).padding.bottom,
        child: Column(children: [
          if (!_retracing) ...[
            _roundButton(Icons.search, _findWhileDriving, tooltip: 'Find fuel, food, police…'),
            const SizedBox(height: 12),
            _roundButton(Icons.history, _showRetrace, tooltip: 'Retrace my trail', color: const Color(0xFFFF7043)),
            const SizedBox(height: 12),
          ],
          _text3d(_toggle3d),
          const SizedBox(height: 12),
          _roundButton(s.settings.voiceOn ? Icons.volume_up : Icons.volume_off, () {
            s.settings.update((st) => st.voiceOn = !st.voiceOn);
            if (!s.settings.voiceOn) s.voice.stop();
          }, tooltip: 'Voice'),
          if (!_follow) ...[
            const SizedBox(height: 12),
            _roundButton(Icons.navigation, () {
              setState(() => _follow = true);
              _followCamera();
            }, tooltip: 'Recenter', color: Brand.amber),
          ],
        ]),
      ),
      // Bottom bar
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: Container(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: const [BoxShadow(blurRadius: 12, color: Colors.black26)],
          ),
          padding: EdgeInsets.fromLTRB(16, 14, 16, MediaQuery.of(context).padding.bottom + 14),
          child: Row(children: [
            IconButton.filled(
              style: IconButton.styleFrom(backgroundColor: Brand.coral),
              iconSize: 30,
              onPressed: _cancel,
              icon: const Icon(Icons.close, color: Colors.white),
              tooltip: 'End trip',
            ),
            Expanded(
              child: Column(children: [
                Text(etaText,
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: cs.primary)),
                Text('${formatDuration(_nav.remainingS)} · ${formatDistance(_nav.remainingM)}',
                    style: const TextStyle(fontSize: 16)),
              ]),
            ),
            IconButton.filledTonal(
                iconSize: 28, onPressed: _shareEta, icon: const Icon(Icons.share), tooltip: 'Share ETA'),
          ]),
        ),
      ),
    ];
  }
}
