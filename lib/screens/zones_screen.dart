import 'dart:math' show Point;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../main.dart';
import '../services/settings.dart';
import '../services/style_builder.dart';
import '../services/zones.dart';
import '../utils/geo.dart';

const zoneRed = '#E53935';
const zoneAmber = '#FFB400';

/// Draw, name, switch on/off and delete your safety avoid zones.
class ZonesScreen extends StatefulWidget {
  const ZonesScreen({super.key, this.start});
  final GeoPoint? start;

  @override
  State<ZonesScreen> createState() => _ZonesScreenState();
}

class _ZonesScreenState extends State<ZonesScreen> {
  final s = Services.i;
  Settings get st => s.settings;
  MapLibreMapController? _map;
  BuiltStyle? _style;

  bool _drawing = false;
  final List<GeoPoint> _draft = [];
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    s.styles.build(night: st.isNight, show3d: false).then((b) {
      if (mounted) setState(() => _style = b);
    });
  }

  // ---------------- Map drawing ----------------

  Future<void> _redraw() async {
    final m = _map;
    if (m == null) return;
    try {
      await m.clearFills();
      await m.clearLines();
      await m.clearCircles();
    } catch (_) {}
    try {
      for (final z in st.zones) {
        if (z.points.length < 3) continue;
        final ring = [...z.points, z.points.first].map((p) => LatLng(p.lat, p.lon)).toList();
        final color = !z.enabled ? '#9E9E9E' : (z.nightOnly ? zoneAmber : zoneRed);
        final selected = z.id == _selectedId;
        await m.addFill(FillOptions(
          geometry: [ring],
          fillColor: color,
          fillOpacity: z.enabled ? 0.28 : 0.12,
        ));
        await m.addLine(LineOptions(
          geometry: ring,
          lineColor: color,
          lineWidth: selected ? 5 : 3,
        ));
      }
      if (_draft.isNotEmpty) {
        final pts = _draft.map((p) => LatLng(p.lat, p.lon)).toList();
        if (_draft.length >= 3) {
          await m.addFill(FillOptions(
            geometry: [
              [...pts, pts.first]
            ],
            fillColor: zoneRed,
            fillOpacity: 0.25,
          ));
        }
        if (_draft.length >= 2) {
          await m.addLine(LineOptions(
            geometry: _draft.length >= 3 ? [...pts, pts.first] : pts,
            lineColor: zoneRed,
            lineWidth: 4,
          ));
        }
        for (final p in pts) {
          await m.addCircle(CircleOptions(
            geometry: p,
            circleRadius: 8,
            circleColor: '#FFFFFF',
            circleStrokeColor: zoneRed,
            circleStrokeWidth: 3,
          ));
        }
      }
    } catch (_) {}
  }

  void _onTap(Point<double> _, LatLng ll) {
    if (_drawing) {
      setState(() => _draft.add(GeoPoint(ll.latitude, ll.longitude)));
      _redraw();
      return;
    }
    // Tap inside a zone to select it.
    final p = GeoPoint(ll.latitude, ll.longitude);
    String? hit;
    for (final z in st.zones.reversed) {
      if (z.points.length >= 3 && pointInPolygon(p, z.points)) {
        hit = z.id;
        break;
      }
    }
    setState(() => _selectedId = hit);
    _redraw();
  }

  void _startDrawing() {
    setState(() {
      _drawing = true;
      _draft.clear();
      _selectedId = null;
    });
    _redraw();
  }

  void _cancelDrawing() {
    setState(() {
      _drawing = false;
      _draft.clear();
    });
    _redraw();
  }

  Future<void> _finishDrawing() async {
    if (_draft.length < 3) return;
    final result = await _askDetails(name: '', nightOnly: false, title: 'New avoid zone');
    if (result == null) return;
    final zone = AvoidZone(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: result.$1,
      points: List.of(_draft),
      nightOnly: result.$2,
    );
    st.update((x) => x.zones.add(zone));
    setState(() {
      _drawing = false;
      _draft.clear();
      _selectedId = zone.id;
    });
    _redraw();
    final km = zone.perimeterM / 1000;
    _toast('Saved "${zone.name}". Routes will now avoid it.'
        '${km > 8 ? ' (Big zone: if the route server refuses it, the app picks the safest normal route and warns you.)' : ''}');
  }

  // ---------------- Zone list actions ----------------

  Future<(String, bool)?> _askDetails(
      {required String name, required bool nightOnly, required String title}) {
    final ctrl = TextEditingController(text: name);
    var night = nightOnly;
    return showDialog<(String, bool)>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          scrollable: true,
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. R59 off-ramp area'),
            ),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Always'), icon: Icon(Icons.shield)),
                ButtonSegment(value: true, label: Text('After dark'), icon: Icon(Icons.nightlight)),
              ],
              selected: {night},
              onSelectionChanged: (v) => setD(() => night = v.first),
            ),
            const SizedBox(height: 8),
            Text(
              night ? 'Avoided from 18:30 to 05:30 only.' : 'Avoided day and night.',
              style: Theme.of(c).textTheme.bodySmall,
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final n = ctrl.text.trim();
                Navigator.pop(c, (n.isEmpty ? 'Avoid zone' : n, night));
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(AvoidZone z) async {
    final r = await _askDetails(name: z.name, nightOnly: z.nightOnly, title: 'Edit zone');
    if (r == null) return;
    st.update((_) {
      z.name = r.$1;
      z.nightOnly = r.$2;
    });
    setState(() {});
    _redraw();
  }

  void _delete(AvoidZone z) {
    final i = st.zones.indexOf(z);
    st.update((x) => x.zones.remove(z));
    setState(() => _selectedId = null);
    _redraw();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Deleted "${z.name}".'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            st.update((x) => x.zones.insert(i.clamp(0, x.zones.length), z));
            if (mounted) setState(() {});
            _redraw();
          },
        ),
      ));
  }

  void _toggle(AvoidZone z, bool on) {
    st.update((_) => z.enabled = on);
    setState(() {});
    _redraw();
  }

  void _flyTo(AvoidZone z) {
    setState(() => _selectedId = z.id);
    _redraw();
    double minLat = 90, maxLat = -90, minLon = 180, maxLon = -180;
    for (final p in z.points) {
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
      if (p.lon < minLon) minLon = p.lon;
      if (p.lon > maxLon) maxLon = p.lon;
    }
    _map?.animateCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(southwest: LatLng(minLat, minLon), northeast: LatLng(maxLat, maxLon)),
      left: 60, right: 60, top: 60, bottom: 60,
    ));
  }

  void _toast(String m) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = _style;
    return Scaffold(
      appBar: AppBar(title: Text(_drawing ? 'Tap the map to outline the area' : 'Safety avoid zones')),
      body: Column(children: [
        Expanded(
          flex: 3,
          child: Stack(children: [
            if (style == null)
              const Center(child: CircularProgressIndicator())
            else
              MapLibreMap(
                styleString: style.styleString,
                initialCameraPosition: CameraPosition(
                  target: LatLng(
                    widget.start?.lat ?? -26.2041,
                    widget.start?.lon ?? 28.0473,
                  ),
                  zoom: widget.start == null ? 10 : 13,
                ),
                myLocationEnabled: widget.start != null,
                // Zones underneath, route lines and dots on top.
                annotationOrder: const [
                  AnnotationType.fill,
                  AnnotationType.line,
                  AnnotationType.circle,
                  AnnotationType.symbol,
                ],
                compassEnabled: false,
                onMapCreated: (c) => _map = c,
                onStyleLoadedCallback: _redraw,
                onMapClick: _onTap,
              ),
            if (_drawing)
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Material(
                  color: cs.surface,
                  elevation: 6,
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(children: [
                      IconButton.filledTonal(
                        tooltip: 'Cancel',
                        onPressed: _cancelDrawing,
                        icon: const Icon(Icons.close),
                      ),
                      const SizedBox(width: 6),
                      IconButton.filledTonal(
                        tooltip: 'Undo last point',
                        onPressed: _draft.isEmpty
                            ? null
                            : () {
                                setState(() => _draft.removeLast());
                                _redraw();
                              },
                        icon: const Icon(Icons.undo),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _draft.length >= 3 ? _finishDrawing : null,
                          icon: const Icon(Icons.check),
                          label: Text(_draft.length >= 3 ? 'Done' : '${3 - _draft.length} more point(s)'),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
        if (!_drawing)
          Expanded(
            flex: 2,
            child: ListView(children: [
              SwitchListTile(
                secondary: const Icon(Icons.shield),
                title: const Text('Avoid my zones', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text('Routes go around the zones that are switched on.'),
                value: st.avoidZones,
                onChanged: (v) {
                  st.update((x) => x.avoidZones = v);
                  setState(() {});
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.nightlight_round),
                title: const Text('Stricter after dark'),
                subtitle: const Text('From 18:30 to 05:30: also avoid "After dark" zones and keep '
                    '300 m further away from every zone.'),
                value: st.nightStricter,
                onChanged: (v) {
                  st.update((x) => x.nightStricter = v);
                  setState(() {});
                },
              ),
              const Divider(height: 1),
              if (st.zones.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No zones yet. Tap "Draw zone", then tap around the area on the map. '
                    'Three or more points make a zone.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ...st.zones.map((z) => ListTile(
                    selected: z.id == _selectedId,
                    leading: Icon(z.nightOnly ? Icons.nightlight : Icons.shield,
                        color: !z.enabled ? null : (z.nightOnly ? Brand.amber : const Color(0xFFE53935))),
                    title: Text(z.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(z.nightOnly ? 'After dark only' : 'Always'),
                    onTap: () => _flyTo(z),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Switch(value: z.enabled, onChanged: (v) => _toggle(z, v)),
                      PopupMenuButton<String>(
                        onSelected: (v) => v == 'edit' ? _edit(z) : _delete(z),
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('Rename / when')),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    ]),
                  )),
              const SizedBox(height: 88),
            ]),
          ),
      ]),
      floatingActionButton: _drawing
          ? null
          : FloatingActionButton.extended(
              onPressed: _startDrawing,
              icon: const Icon(Icons.draw),
              label: const Text('Draw zone'),
            ),
    );
  }
}
