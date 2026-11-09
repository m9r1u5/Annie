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
import '../services/voice_service.dart';
import '../utils/geo.dart';
import 'maps_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

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
    _nav.removeListener(_onNav);
    s.settings.removeListener(_onSettings);
    WakelockPlus.disable();
    super.dispose();
  }

  // ---------------- Map style ----------------

  Future<void> _buildStyle() async {
    final want3d = _is3d;
    final built = await s.styles.build(night: _styleNight, show3d: want3d);
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
    if (initial && _mode == Mode.browse) {
      _map?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(p.latitude, p.longitude), 14));
    }
    if (_mode == Mode.driving) {
      _nav.onPosition(GeoPoint(p.latitude, p.longitude), p.speed,
          p.heading >= 0 ? p.heading : null);
      if (_follow) _followCamera();
    }
  }

  void _followCamera() {
    final target = _nav.snapped ?? _here;
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
      setState(() => _route = r);
      await _drawRoute();
      _fitRoute(r);
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
    try {
      final r = await s.routing.route(from, dest.point, headingDeg: heading);
      if (!mounted || _mode != Mode.driving) return;
      _route = r;
      _nav.setRoute(r);
      await _drawRoute();
    } catch (_) {
      // Keep the old route; another attempt follows after 15 seconds.
    }
  }

  Future<void> _drawRoute() async {
    final m = _map;
    if (m == null) return;
    try {
      await m.clearLines();
      await m.clearCircles();
    } catch (_) {}
    final r = _route;
    if (r == null || _mode == Mode.browse) return;
    final geom = r.points.map((p) => LatLng(p.lat, p.lon)).toList();
    try {
      await m.addLine(LineOptions(
          geometry: geom, lineColor: '#0D47A1', lineWidth: 11, lineOpacity: 0.9));
      await m.addLine(LineOptions(
          geometry: geom, lineColor: Brand.routeBlue, lineWidth: 7, lineOpacity: 1));
      final d = r.points.last;
      await m.addCircle(CircleOptions(
        geometry: LatLng(d.lat, d.lon),
        circleRadius: 9,
        circleColor: '#E85D4A',
        circleStrokeWidth: 3,
        circleStrokeColor: '#FFFFFF',
      ));
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
    _nav.start(r);
    if (_pos != null) _onPosition(_pos!);
    _followCamera();
  }

  void _cancel() {
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
          const SizedBox(width: 12),
          Expanded(child: _favButton(Icons.work, 'Work', st.work, false)),
        ]),
      ],
    );
  }

  Widget _favButton(IconData icon, String label, Place? place, bool isHome) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      ),
      icon: Icon(icon),
      label: Text(place == null ? 'Set $label' : label, style: const TextStyle(fontSize: 16)),
      onPressed: () => place == null ? _setFavourite(isHome) : _routeTo(place),
      onLongPress: () => _setFavourite(isHome),
    );
  }

  Widget _previewCard(ColorScheme cs) {
    final r = _route;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_dest?.name ?? '',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        if ((_dest?.address ?? '').isNotEmpty)
          Text(_dest!.address, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.onSurfaceVariant)),
        const SizedBox(height: 10),
        if (_loadingRoute)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (r != null)
          Text('${formatDuration(r.totalS)} · ${formatDistance(r.totalM)}',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: cs.primary)),
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
              onPressed: r == null ? null : _startDriving,
              icon: const Icon(Icons.navigation),
              label: const Text('Go'),
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
            child: Row(children: [
              Icon(VoiceService.iconFor(m), color: Colors.white, size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(formatDistance(_nav.distToNextM),
                      style: const TextStyle(
                          color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800)),
                  Text(
                    m == null || m.street.isEmpty
                        ? (actionText.isEmpty ? '' : actionText[0].toUpperCase() + actionText.substring(1))
                        : m.street,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
      if (_nav.rerouting)
        Positioned(
          top: top + 120,
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
      // Speed bubble
      Positioned(
        left: 12,
        bottom: 150 + MediaQuery.of(context).padding.bottom,
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: cs.surface,
            shape: BoxShape.circle,
            boxShadow: const [BoxShadow(blurRadius: 8, color: Colors.black26)],
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(_nav.speedKmh.round().toString(),
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
            const Text('km/h', style: TextStyle(fontSize: 11)),
          ]),
        ),
      ),
      // Right buttons
      Positioned(
        right: 12,
        bottom: 150 + MediaQuery.of(context).padding.bottom,
        child: Column(children: [
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
