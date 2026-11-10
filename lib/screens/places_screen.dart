import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../services/places_service.dart';
import '../services/settings.dart';
import '../utils/geo.dart';

/// Find fuel, shops, hospitals, police, etc. near you or along your route.
/// Returns the chosen [Place].
class PlacesScreen extends StatefulWidget {
  const PlacesScreen({super.key, required this.here, this.route = const [], this.category});
  final GeoPoint here;
  final List<GeoPoint> route; // the rest of your route, if you're on one
  final PlaceCategory? category;

  @override
  State<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends State<PlacesScreen> {
  PlaceCategory? _cat;
  late bool _along = widget.route.length >= 2;
  bool _loading = false;
  List<FoundPlace> _results = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.category != null) _pick(widget.category!);
  }

  Future<void> _pick(PlaceCategory c) async {
    setState(() {
      _cat = c;
      _loading = true;
      _error = null;
      _results = [];
    });
    final places = Services.i.places;
    try {
      final r = _along
          ? await places.alongRoute(c, widget.route, widget.here)
          : await places.nearby(c, widget.here);
      if (!mounted) return;
      setState(() {
        _results = r;
        if (r.isEmpty) {
          _error = places.lastWasOffline
              ? 'Nothing found in your offline maps${_along ? ' along your route' : ' nearby'}.'
              : 'Nothing found${_along ? ' along your route' : ' nearby'}.';
        }
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Search failed. Check your signal.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cat = _cat;
    return PopScope(
      canPop: cat == null || widget.category != null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _cat = null); // back to the categories
      },
      child: Scaffold(
        appBar: AppBar(title: Text(cat == null ? 'Find nearby' : cat.label)),
        body: Column(children: [
          if (widget.route.length >= 2)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Along my route'), icon: Icon(Icons.route)),
                  ButtonSegment(value: false, label: Text('Near me'), icon: Icon(Icons.near_me)),
                ],
                selected: {_along},
                onSelectionChanged: (v) {
                  setState(() => _along = v.first);
                  if (_cat != null) _pick(_cat!);
                },
              ),
            ),
          Expanded(child: cat == null ? _grid() : _list()),
        ]),
      ),
    );
  }

  Widget _grid() {
    return GridView.count(
      crossAxisCount: 3,
      padding: const EdgeInsets.all(12),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      children: [
        for (final c in placeCategories)
          Material(
            color: c.color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () => _pick(c),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: c.color,
                  child: Icon(c.icon, color: Colors.white, size: 28),
                ),
                const SizedBox(height: 8),
                Text(c.label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              ]),
            ),
          ),
      ],
    );
  }

  Widget _list() {
    final cat = _cat!;
    final cs = Theme.of(context).colorScheme;
    if (_loading) return const Center(child: CircularProgressIndicator());
    return ListView(children: [
      if (Services.i.places.lastWasOffline && _results.isNotEmpty)
        const ListTile(
          dense: true,
          leading: Icon(Icons.cloud_off),
          title: Text('From your offline maps (no opening hours or phone numbers)'),
        ),
      if (!Services.i.settings.hasTraffic)
        const ListTile(
          dense: true,
          leading: Icon(Icons.info_outline),
          title: Text('Add your TomTom key in Settings for more places, opening hours and phone numbers.'),
        ),
      if (_error != null)
        Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)),
      for (final p in _results)
        ListTile(
          leading: CircleAvatar(backgroundColor: cat.color, child: Icon(cat.icon, color: Colors.white)),
          title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (p.address.isNotEmpty) Text(p.address, maxLines: 2, overflow: TextOverflow.ellipsis),
            Wrap(spacing: 10, children: [
              if (p.distanceM != null)
                Text(formatDistance(p.distanceM!), style: const TextStyle(fontWeight: FontWeight.w600)),
              if (_along && p.detourS != null)
                Text('+${formatDuration(p.detourS!)} detour', style: TextStyle(color: cs.primary)),
              if (p.hoursText != null)
                Text(p.hoursText!,
                    style: TextStyle(
                        color: p.openNow == true ? const Color(0xFF2E7D32) : const Color(0xFFD32F2F),
                        fontWeight: FontWeight.w600)),
            ]),
          ]),
          isThreeLine: true,
          trailing: p.phone == null
              ? const Icon(Icons.chevron_right)
              : IconButton.filledTonal(
                  tooltip: 'Call',
                  icon: const Icon(Icons.call),
                  onPressed: () => launchUrl(Uri.parse('tel:${p.phone!.replaceAll(' ', '')}')),
                ),
          onTap: () => Navigator.pop(context, p.toPlace()),
        ),
      const SizedBox(height: 24),
    ]);
  }
}
