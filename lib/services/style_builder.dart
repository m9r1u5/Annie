import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../config.dart';
import 'map_pack_service.dart';

class BuiltStyle {
  /// Value for MapLibreMap.styleString (a URL or a file path).
  final String styleString;
  final bool offline;
  final List<String> buildingLayerIds;
  const BuiltStyle(this.styleString, this.offline, this.buildingLayerIds);
}

/// Builds the map style from the province packs on the phone.
/// With no packs it falls back to the online map.
class StyleBuilder {
  StyleBuilder(this.packs);
  final MapPackService packs;

  /// [trafficKey]: TomTom key to show live traffic colours on roads.
  Future<BuiltStyle> build({required bool night, required bool show3d, String? trafficKey}) async {
    final assets = await packs.assetsPath();
    final installed = await packs.installedPackPaths();
    if (assets == null || installed.isEmpty) {
      return const BuiltStyle(AppConfig.onlineStyleUrl, false, []);
    }

    final flavor = night ? 'dark' : 'light';
    final layersFile = File('$assets/layers-$flavor.json');
    final template = (jsonDecode(await layersFile.readAsString()) as List)
        .cast<Map<String, dynamic>>();

    final sources = <String, dynamic>{};
    installed.forEach((id, path) {
      sources[id] = {
        'type': 'vector',
        'url': 'pmtiles://file://$path',
        'attribution':
            '© OpenStreetMap contributors · Protomaps',
      };
    });

    final layers = <Map<String, dynamic>>[];
    for (final layer in template) {
      if (layer['type'] == 'background' || !layer.containsKey('source')) {
        layers.add(layer);
        continue;
      }
      // Same layer for every province, so drawing order stays correct.
      for (final id in installed.keys) {
        final copy = Map<String, dynamic>.from(layer);
        copy['id'] = '${layer['id']}__$id';
        copy['source'] = id;
        layers.add(copy);
      }
    }

    final buildingIds = <String>[];
    for (final id in installed.keys) {
      final lid = '3d-buildings__$id';
      buildingIds.add(lid);
      layers.add({
        'id': lid,
        'type': 'fill-extrusion',
        'source': id,
        'source-layer': 'buildings',
        'minzoom': 14,
        'layout': {'visibility': show3d ? 'visible' : 'none'},
        'paint': {
          'fill-extrusion-color': night ? '#3a4150' : '#d9d3c7',
          'fill-extrusion-height': [
            'coalesce',
            ['get', 'height'],
            6
          ],
          'fill-extrusion-base': [
            'coalesce',
            ['get', 'min_height'],
            0
          ],
          'fill-extrusion-opacity': 0.85,
        },
      });
    }

    // Live traffic from TomTom, drawn on the roads but under the labels.
    final key = trafficKey?.trim() ?? '';
    if (key.isNotEmpty) {
      sources['traffic'] = {
        'type': 'vector',
        'tiles': [
          'https://api.tomtom.com/traffic/map/4/tile/flow/relative/{z}/{x}/{y}.pbf?key=${Uri.encodeQueryComponent(key)}'
        ],
        'minzoom': 6,
        'maxzoom': 16,
        'attribution': 'Traffic © TomTom',
      };
      final traffic = {
        'id': 'traffic-flow',
        'type': 'line',
        'source': 'traffic',
        'source-layer': 'Traffic flow',
        'minzoom': 8,
        'filter': ['any', ['has', 'traffic_level'], ['has', 'road_closure']],
        'layout': {'line-cap': 'round', 'line-join': 'round'},
        'paint': {
          'line-color': [
            'case',
            ['has', 'road_closure'], '#6A1B9A',
            ['<', ['get', 'traffic_level'], 0.4], '#D32F2F',
            ['<', ['get', 'traffic_level'], 0.75], '#FB8C00',
            '#43A047'
          ],
          'line-width': ['interpolate', ['linear'], ['zoom'], 8, 1.5, 12, 3, 16, 6],
          'line-opacity': [
            'case',
            ['has', 'road_closure'], 0.95,
            ['>=', ['get', 'traffic_level'], 0.75], 0.5,
            0.95
          ],
        },
      };
      final firstLabel = layers.indexWhere((l) => l['type'] == 'symbol');
      layers.insert(firstLabel < 0 ? layers.length : firstLabel, traffic);
    }

    final style = {
      'version': 8,
      'name': 'SafeRoute $flavor',
      'glyphs': 'file://$assets/fonts/{fontstack}/{range}.pbf',
      'sprite': 'file://$assets/sprites/v4/$flavor',
      'sources': sources,
      'layers': layers,
    };

    final dir = await getApplicationSupportDirectory();
    // Clear old style files; a new name makes the map reload the style.
    for (final f in dir.listSync().whereType<File>()) {
      if (f.path.split('/').last.startsWith('style_')) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final out = File('${dir.path}/style_${flavor}_$stamp.json');
    await out.writeAsString(jsonEncode(style));
    return BuiltStyle(out.path, true, buildingIds);
  }
}
