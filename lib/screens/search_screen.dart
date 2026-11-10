import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';
import '../services/settings.dart';
import '../utils/geo.dart';
import 'favourites_screen.dart';

/// Search for an address or place. Returns the chosen [Place].
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.near, this.title = 'Where to?'});
  final GeoPoint? near;
  final String title;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<Place> _results = [];
  bool _loading = false;
  String? _error;
  bool _offline = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () => _run(q));
  }

  Future<void> _run(String q) async {
    if (q.trim().length < 3) {
      setState(() {
        _results = [];
        _error = null;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final r = await Services.i.search.search(q, near: widget.near);
      if (!mounted || _ctrl.text != q) return;
      setState(() {
        _results = r;
        _offline = Services.i.search.lastWasOffline;
        _error = r.isEmpty
            ? (_offline ? 'Nothing found in your downloaded provinces.' : 'Nothing found in South Africa.')
            : null;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No signal, and no offline search on this phone yet. '
            'Download your province under Offline maps. Your saved places work offline.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Lets you type coordinates like "-26.1, 28.05" (works offline).
  Place? _coordinates(String q) {
    final m = RegExp(r'^\s*(-?\d+(?:\.\d+)?)\s*[, ]\s*(-?\d+(?:\.\d+)?)\s*$').firstMatch(q);
    if (m == null) return null;
    final lat = double.parse(m.group(1)!), lon = double.parse(m.group(2)!);
    if (lat.abs() > 90 || lon.abs() > 180) return null;
    return Place('Coordinates', '$lat, $lon', lat, lon);
  }

  Widget _tile(Place p, IconData icon) {
    String? dist;
    if (widget.near != null) dist = formatDistance(distanceM(widget.near!, p.point));
    return ListTile(
      leading: CircleAvatar(child: Icon(icon)),
      title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: p.address.isEmpty
          ? null
          : Text(p.address, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: dist == null ? null : Text(dist),
      onTap: () => Navigator.pop(context, p),
      onLongPress: () async {
        final name = await askPlaceName(context, p.name == 'Coordinates' ? '' : p.name);
        if (name == null || !mounted) return;
        Services.i.settings
            .saveFavourite(Place(name, p.address.isEmpty ? p.name : p.address, p.lat, p.lon));
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved "$name".')));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final st = Services.i.settings;
    final q = _ctrl.text;
    final coord = _coordinates(q);
    final showSaved = q.trim().length < 3;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          textInputAction: TextInputAction.search,
          style: const TextStyle(fontSize: 18),
          decoration: InputDecoration(
            hintText: widget.title,
            border: InputBorder.none,
            suffixIcon: q.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _ctrl.clear();
                      _onChanged('');
                      setState(() {});
                    }),
          ),
          onChanged: (v) {
            setState(() {});
            _onChanged(v);
          },
          onSubmitted: _run,
        ),
      ),
      body: ListView(
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (coord != null) _tile(coord, Icons.pin_drop),
          if (showSaved) ...[
            if (st.home != null) _tile(st.home!, Icons.home),
            if (st.work != null) _tile(st.work!, Icons.work),
            if (st.favourites.isNotEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('Saved', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ...st.favourites.map((p) => _tile(p, Icons.star)),
            if (st.recents.isNotEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('Recent', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ...st.recents.map((p) => _tile(p, Icons.history)),
            if (st.recents.isEmpty && st.home == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Type an address, a place name or a suburb.\n\nTips: press and hold a search result to save it. '
                  'On the map, press and hold anywhere to drive there.',
                  textAlign: TextAlign.center,
                ),
              ),
          ] else ...[
            if (_offline && _results.isNotEmpty)
              const ListTile(
                dense: true,
                leading: Icon(Icons.cloud_off),
                title: Text('No signal: showing results from your offline maps'),
              ),
            if (_error != null)
              Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)),
            ..._results.map((p) => _tile(p, Icons.place)),
          ],
        ],
      ),
    );
  }
}
