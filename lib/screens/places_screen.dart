import 'dart:async';

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

  // Search box
  final _ctrl = TextEditingController();
  Timer? _debounce;
  bool _searchingName = false;
  List<FoundPlace> _nameResults = [];
  String _nameQuery = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onType(String v) {
    setState(() {}); // filter the list straight away
    _debounce?.cancel();
    final q = v.trim();
    if (q.length < 2) {
      setState(() {
        _nameResults = [];
        _nameQuery = '';
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 500), () => _searchName(q));
  }

  /// Searches every business by name ("Mica"), not just this category.
  Future<void> _searchName(String q) async {
    setState(() => _searchingName = true);
    final r = await Services.i.places.byName(q, widget.here, route: _along ? widget.route : const []);
    if (!mounted || _ctrl.text.trim() != q) return;
    setState(() {
      _nameResults = r;
      _nameQuery = q;
      _searchingName = false;
    });
  }

  /// Category results matching what you typed, then other places with that name.
  List<FoundPlace> get _shown {
    final q = _ctrl.text.trim().toLowerCase();
    if (q.isEmpty) return _results;
    bool hit(FoundPlace p) => p.name.toLowerCase().contains(q) || p.address.toLowerCase().contains(q);
    final mine = _results.where(hit).toList();
    final seen = mine.map((p) => '${p.name}|${p.point.lat.toStringAsFixed(4)}').toSet();
    final more = _nameQuery.toLowerCase() == q
        ? _nameResults.where((p) => seen.add('${p.name}|${p.point.lat.toStringAsFixed(4)}')).toList()
        : <FoundPlace>[];
    return [...mine, ...more];
  }

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
                  if (_ctrl.text.trim().length >= 2) _searchName(_ctrl.text.trim());
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _ctrl,
              onChanged: _onType,
              textInputAction: TextInputAction.search,
              onSubmitted: (v) {
                if (v.trim().length >= 2) _searchName(v.trim());
              },
              decoration: InputDecoration(
                hintText: cat == null ? 'Search any shop or place by name' : 'Search ${cat.label.toLowerCase()} by name',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _ctrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _ctrl.clear();
                          _onType('');
                        },
                      ),
                filled: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
            ),
          ),
          Expanded(child: cat == null && _ctrl.text.trim().isEmpty ? _grid() : _list()),
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
      childAspectRatio: 0.85,
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
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(c.label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, height: 1.1)),
                ),
              ]),
            ),
          ),
      ],
    );
  }

  Widget _list() {
    final cat = _cat;
    final cs = Theme.of(context).colorScheme;
    if (_loading) return const Center(child: CircularProgressIndicator());
    final shown = _shown;
    final typed = _ctrl.text.trim();
    return ListView(children: [
      if (_searchingName) const LinearProgressIndicator(),
      if (typed.isNotEmpty && shown.isEmpty && !_searchingName && typed.length >= 2)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Nothing called "$typed" found${_along ? ' along your route' : ' nearby'}.',
              textAlign: TextAlign.center),
        ),
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
      if (_error != null && typed.isEmpty)
        Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)),
      for (final p in shown)
        ListTile(
          leading: CircleAvatar(
              backgroundColor: cat != null && _results.contains(p) ? cat.color : cs.primary,
              child: Icon(cat != null && _results.contains(p) ? cat.icon : Icons.storefront, color: Colors.white)),
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
