import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../main.dart';
import '../services/place_share.dart';
import '../services/settings.dart';
import '../utils/geo.dart';
import 'search_screen.dart';

/// Asks for a name for a saved place. Returns null if cancelled.
Future<String?> askPlaceName(BuildContext context, String initial, {String title = 'Save place'}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      scrollable: true,
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

  /// Tick the places to send, then share them as one message.
  Future<void> _shareSome() async {
    final chosen = Set<Place>.of(st.favourites);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: const Text('Share which places?'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(shrinkWrap: true, children: [
              CheckboxListTile(
                title: const Text('All', style: TextStyle(fontWeight: FontWeight.w700)),
                value: chosen.length == st.favourites.length,
                onChanged: (v) => setD(() {
                  chosen.clear();
                  if (v == true) chosen.addAll(st.favourites);
                }),
              ),
              for (final p in st.favourites)
                CheckboxListTile(
                  title: Text(p.name),
                  subtitle: p.address.isEmpty ? null : Text(p.address, maxLines: 1, overflow: TextOverflow.ellipsis),
                  value: chosen.contains(p),
                  onChanged: (v) => setD(() => v == true ? chosen.add(p) : chosen.remove(p)),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton.icon(
              onPressed: () => Navigator.pop(c, true),
              icon: const Icon(Icons.share),
              label: const Text('Share'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || chosen.isEmpty) return;
    final list = st.favourites.where(chosen.contains).toList();
    await Share.share(PlaceShare.message(list), subject: 'Saved places from SafeRoute SA');
  }

  /// Reads places from a copied message (SafeRoute share or Google Maps link).
  Future<void> _import() async {
    final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    var found = PlaceShare.parse(clip);
    if (!mounted) return;
    if (found.isEmpty) {
      // Nothing usable copied: let them paste it.
      final ctrl = TextEditingController();
      final text = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          scrollable: true,
          title: const Text('Import places'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Copy the message you were sent (or a Google Maps link) and paste it here.'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              maxLines: 5,
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Paste here'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('Import')),
          ],
        ),
      );
      if (text == null) return;
      found = PlaceShare.parse(text);
      if (found.isEmpty) {
        _toast('No places found in that text.');
        return;
      }
    }
    if (!mounted) return;
    final chosen = Set<Place>.of(found);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: Text('Add ${found.length == 1 ? 'this place' : '${found.length} places'}?'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(shrinkWrap: true, children: [
              for (final p in found)
                CheckboxListTile(
                  title: Text(p.name),
                  subtitle: Text(
                    st.favouriteAt(p) != null
                        ? 'Already saved (will be updated)'
                        : (p.address.isEmpty ? '${p.lat.toStringAsFixed(5)}, ${p.lon.toStringAsFixed(5)}' : p.address),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  value: chosen.contains(p),
                  onChanged: (v) => setD(() => v == true ? chosen.add(p) : chosen.remove(p)),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Add to Saved')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    for (final p in found.reversed.where(chosen.contains)) {
      st.saveFavourite(p);
    }
    setState(() {});
    _toast('Added ${chosen.length} place(s) to Saved.');
  }

  void _toast(String m) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
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
      appBar: AppBar(
        title: const Text('Saved places'),
        actions: [
          IconButton(icon: const Icon(Icons.download), tooltip: 'Import places', onPressed: _import),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Share places',
            onPressed: st.favourites.isEmpty ? null : _shareSome,
          ),
        ],
      ),
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
                    onSelected: (v) => v == 'share'
                        ? Share.share(PlaceShare.message([p]), subject: p.name)
                        : v == 'rename'
                            ? _rename(p)
                            : _delete(p),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'share', child: Text('Share')),
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
