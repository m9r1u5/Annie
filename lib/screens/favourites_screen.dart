import 'package:flutter/material.dart';

import '../main.dart';
import '../services/settings.dart';
import '../utils/geo.dart';
import 'search_screen.dart';

/// Asks for a name for a saved place. Returns null if cancelled.
Future<String?> askPlaceName(BuildContext context, String initial, {String title = 'Save place'}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          labelText: 'Name',
          hintText: 'e.g. Mom, Gym, Site office',
        ),
        onSubmitted: (v) {
          if (v.trim().isNotEmpty) Navigator.pop(c, v.trim());
        },
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final v = ctrl.text.trim();
            if (v.isNotEmpty) Navigator.pop(c, v);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// Your saved places. Tap one to drive there.
class FavouritesScreen extends StatefulWidget {
  const FavouritesScreen({super.key, this.near});
  final GeoPoint? near;

  @override
  State<FavouritesScreen> createState() => _FavouritesScreenState();
}

class _FavouritesScreenState extends State<FavouritesScreen> {
  Settings get st => Services.i.settings;

  Future<void> _add() async {
    final place = await Navigator.push<Place>(
      context,
      MaterialPageRoute(builder: (_) => SearchScreen(near: widget.near, title: 'Find an address to save')),
    );
    if (place == null || !mounted) return;
    final name = await askPlaceName(context, place.name == 'Coordinates' ? '' : place.name);
    if (name == null) return;
    st.saveFavourite(Place(name, place.address.isEmpty ? place.name : place.address, place.lat, place.lon));
    setState(() {});
  }

  Future<void> _rename(Place p) async {
    final name = await askPlaceName(context, p.name, title: 'Rename');
    if (name == null) return;
    st.saveFavourite(Place(name, p.address, p.lat, p.lon));
    setState(() {});
  }

  Future<void> _delete(Place p) async {
    st.removeFavourite(p);
    setState(() {});
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Removed "${p.name}".'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            st.saveFavourite(p);
            if (mounted) setState(() {});
          },
        ),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final favs = st.favourites;
    return Scaffold(
      appBar: AppBar(title: const Text('Saved places')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add_location_alt),
        label: const Text('Add place'),
      ),
      body: favs.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No saved places yet.\n\nTap "Add place" to search for an address and save it, '
                  'or tap the star when you pick a destination.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16),
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: favs.length,
              itemBuilder: (context, i) {
                final p = favs[i];
                final dist = widget.near == null ? null : formatDistance(distanceM(widget.near!, p.point));
                return ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.star)),
                  title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    [if (p.address.isNotEmpty) p.address, if (dist != null) dist].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.pop(context, p),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) => v == 'rename' ? _rename(p) : _delete(p),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('Rename')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
