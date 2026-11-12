import 'dart:convert';

import 'settings.dart';

/// Turns saved places into a message anyone can read (with Google Maps links),
/// plus a code SafeRoute can import from; and reads such messages back.
class PlaceShare {
  static const _tag = '#SR1:';

  static String message(List<Place> places) {
    final b = StringBuffer();
    for (final p in places) {
      b.writeln('📍 ${p.name}');
      if (p.address.isNotEmpty && p.address != p.name) b.writeln(p.address);
      b.writeln('https://maps.google.com/?q=${p.lat.toStringAsFixed(6)},${p.lon.toStringAsFixed(6)}');
      b.writeln();
    }
    final data = places.map((p) => [p.name, p.address, _r(p.lat), _r(p.lon)]).toList();
    final code = base64Url.encode(utf8.encode(jsonEncode(data))).replaceAll('=', '');
    b.writeln('SafeRoute SA users: copy this whole message, then open Saved › Import.');
    b.write('$_tag$code');
    return b.toString();
  }

  static double _r(double v) => double.parse(v.toStringAsFixed(6));

  /// Places found in pasted text: the SafeRoute code if present, otherwise
  /// Google Maps links / "lat, lon" coordinates (named from the line above).
  static List<Place> parse(String text) {
    final i = text.indexOf(_tag);
    if (i >= 0) {
      try {
        var code = text.substring(i + _tag.length).trim().split(RegExp(r'\s')).first;
        while (code.length % 4 != 0) {
          code += '=';
        }
        final list = jsonDecode(utf8.decode(base64Url.decode(code))) as List;
        return [
          for (final e in list)
            Place(e[0] as String, e[1] as String? ?? '', (e[2] as num).toDouble(), (e[3] as num).toDouble())
        ];
      } catch (_) {}
    }
    final out = <Place>[];
    final lines = text.split('\n');
    final coord = RegExp(r'(-?\d{1,2}\.\d{3,})\s*,\s*(-?\d{1,3}\.\d{3,})');
    String? lastName;
    var n = 1;
    for (final raw in lines) {
      final line = raw.trim();
      final m = coord.firstMatch(line);
      if (m != null) {
        final lat = double.parse(m.group(1)!), lon = double.parse(m.group(2)!);
        if (lat.abs() <= 90 && lon.abs() <= 180) {
          out.add(Place(lastName ?? 'Shared place ${n++}', '', lat, lon));
          lastName = null;
        }
      } else if (line.startsWith('📍')) {
        lastName = line.replaceFirst('📍', '').trim();
      } else if (line.isNotEmpty && !line.startsWith('http') && lastName == null) {
        lastName = line; // first line above the link is the name
      }
    }
    return out;
  }
}
