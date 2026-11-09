import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../utils/geo.dart';
import 'settings.dart';

/// Address and place search with Photon (OpenStreetMap data).
class SearchService {
  Future<List<Place>> search(String query, {GeoPoint? near}) async {
    final q = query.trim();
    if (q.length < 3) return [];
    final b = AppConfig.saBbox;
    final params = <String, String>{
      'q': q,
      'limit': '12',
      'lang': 'en',
      'bbox': '${b[0]},${b[1]},${b[2]},${b[3]}',
    };
    if (near != null) {
      params['lat'] = near.lat.toStringAsFixed(5);
      params['lon'] = near.lon.toStringAsFixed(5);
    }
    final uri = Uri.parse(AppConfig.photonUrl).replace(queryParameters: params);
    final res = await http
        .get(uri, headers: {'User-Agent': AppConfig.userAgent})
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception('Search is not available right now (HTTP ${res.statusCode}).');
    }
    final features = (jsonDecode(res.body) as Map<String, dynamic>)['features'] as List;
    final out = <Place>[];
    for (final fRaw in features) {
      final f = fRaw as Map<String, dynamic>;
      final props = f['properties'] as Map<String, dynamic>;
      if ((props['countrycode'] as String?)?.toUpperCase() != 'ZA') continue;
      final coords = (f['geometry'] as Map)['coordinates'] as List;
      final street = [props['housenumber'], props['street']]
          .where((e) => e != null && e.toString().isNotEmpty)
          .join(' ');
      final name = (props['name'] as String?) ?? (street.isNotEmpty ? street : 'Location');
      final parts = <String>[
        if (street.isNotEmpty && street != name) street,
        if (props['district'] != null) props['district'].toString(),
        if (props['city'] != null) props['city'].toString(),
        if (props['state'] != null) props['state'].toString(),
      ];
      out.add(Place(
        name,
        parts.toSet().join(', '),
        (coords[1] as num).toDouble(),
        (coords[0] as num).toDouble(),
      ));
    }
    return out;
  }
}
