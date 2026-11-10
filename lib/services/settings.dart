import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/geo.dart';
import 'zones.dart';

class Place {
  final String name;
  final String address;
  final double lat;
  final double lon;
  const Place(this.name, this.address, this.lat, this.lon);

  GeoPoint get point => GeoPoint(lat, lon);

  Map<String, dynamic> toJson() =>
      {'name': name, 'address': address, 'lat': lat, 'lon': lon};
  factory Place.fromJson(Map<String, dynamic> j) => Place(
        j['name'] as String? ?? '',
        j['address'] as String? ?? '',
        (j['lat'] as num).toDouble(),
        (j['lon'] as num).toDouble(),
      );
}

enum ThemeChoice { auto, day, night }

/// All user settings, saved on the phone.
class Settings extends ChangeNotifier {
  late SharedPreferences _p;

  bool voiceOn = true;
  String voiceLang = 'en'; // 'en' or 'af'
  bool wifiOnly = true;
  bool keepScreenOn = true;
  bool avoidTolls = false;
  bool avoidHighways = false;
  bool avoidGravel = true;
  ThemeChoice theme = ThemeChoice.auto;
  Place? home;
  Place? work;
  List<Place> recents = [];
  List<Place> favourites = [];
  List<AvoidZone> zones = [];
  bool avoidZones = true;
  bool nightStricter = true;
  String tomtomKey = '';
  bool showTraffic = true;
  bool autoFaster = true;
  DateTime? lastMapCheck;

  /// Pack id -> map version installed (e.g. "20261108").
  Map<String, String> installedPacks = {};
  String? installedAssetsVersion;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    voiceOn = _p.getBool('voiceOn') ?? true;
    voiceLang = _p.getString('voiceLang') ?? 'en';
    wifiOnly = _p.getBool('wifiOnly') ?? true;
    keepScreenOn = _p.getBool('keepScreenOn') ?? true;
    avoidTolls = _p.getBool('avoidTolls') ?? false;
    avoidHighways = _p.getBool('avoidHighways') ?? false;
    avoidGravel = _p.getBool('avoidGravel') ?? true;
    theme = ThemeChoice.values[_p.getInt('theme') ?? 0];
    home = _readPlace('home');
    work = _readPlace('work');
    final r = _p.getString('recents');
    if (r != null) {
      recents = (jsonDecode(r) as List)
          .map((e) => Place.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    final z = _p.getString('zones');
    if (z != null) {
      zones = (jsonDecode(z) as List)
          .map((e) => AvoidZone.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    avoidZones = _p.getBool('avoidZones') ?? true;
    nightStricter = _p.getBool('nightStricter') ?? true;
    tomtomKey = _p.getString('tomtomKey') ?? '';
    showTraffic = _p.getBool('showTraffic') ?? true;
    autoFaster = _p.getBool('autoFaster') ?? true;
    final f = _p.getString('favourites');
    if (f != null) {
      favourites = (jsonDecode(f) as List)
          .map((e) => Place.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    final lc = _p.getInt('lastMapCheck');
    lastMapCheck = lc == null ? null : DateTime.fromMillisecondsSinceEpoch(lc);
    final ip = _p.getString('installedPacks');
    if (ip != null) {
      installedPacks = Map<String, String>.from(jsonDecode(ip) as Map);
    }
    installedAssetsVersion = _p.getString('installedAssetsVersion');
  }

  Place? _readPlace(String key) {
    final s = _p.getString(key);
    if (s == null) return null;
    return Place.fromJson(jsonDecode(s) as Map<String, dynamic>);
  }

  void _savePlace(String key, Place? place) {
    if (place == null) {
      _p.remove(key);
    } else {
      _p.setString(key, jsonEncode(place.toJson()));
    }
  }

  void update(void Function(Settings s) change) {
    change(this);
    _p.setBool('voiceOn', voiceOn);
    _p.setString('voiceLang', voiceLang);
    _p.setBool('wifiOnly', wifiOnly);
    _p.setBool('keepScreenOn', keepScreenOn);
    _p.setBool('avoidTolls', avoidTolls);
    _p.setBool('avoidHighways', avoidHighways);
    _p.setBool('avoidGravel', avoidGravel);
    _p.setInt('theme', theme.index);
    _savePlace('home', home);
    _savePlace('work', work);
    _p.setString('recents', jsonEncode(recents.map((e) => e.toJson()).toList()));
    _p.setString('favourites', jsonEncode(favourites.map((e) => e.toJson()).toList()));
    _p.setString('zones', jsonEncode(zones.map((e) => e.toJson()).toList()));
    _p.setBool('avoidZones', avoidZones);
    _p.setBool('nightStricter', nightStricter);
    _p.setString('tomtomKey', tomtomKey);
    _p.setBool('showTraffic', showTraffic);
    _p.setBool('autoFaster', autoFaster);
    if (lastMapCheck != null) {
      _p.setInt('lastMapCheck', lastMapCheck!.millisecondsSinceEpoch);
    }
    _p.setString('installedPacks', jsonEncode(installedPacks));
    if (installedAssetsVersion != null) {
      _p.setString('installedAssetsVersion', installedAssetsVersion!);
    }
    notifyListeners();
  }

  void addRecent(Place place) {
    update((s) {
      s.recents.removeWhere((p) =>
          (p.lat - place.lat).abs() < 1e-5 && (p.lon - place.lon).abs() < 1e-5);
      s.recents.insert(0, place);
      if (s.recents.length > 15) s.recents = s.recents.sublist(0, 15);
    });
  }

  bool get hasTraffic => tomtomKey.trim().isNotEmpty;

  /// After dark: 18:30 to 05:30.
  static bool get isAfterDark {
    final now = DateTime.now();
    final mins = now.hour * 60 + now.minute;
    return mins >= 18 * 60 + 30 || mins < 5 * 60 + 30;
  }

  /// Extra margin around zones at night when "stricter after dark" is on.
  static const nightMarginM = 300.0;

  /// Zones that apply right now (switched on, and the time is right).
  List<ActiveZone> activeZones() {
    if (!avoidZones) return const [];
    final dark = isAfterDark;
    final margin = dark && nightStricter ? nightMarginM : 0.0;
    return zones
        .where((z) => z.enabled && z.points.length >= 3 && (!z.nightOnly || dark))
        .map((z) => ActiveZone(z, z.grown(margin)))
        .toList();
  }

  static bool samePlace(Place a, Place b) =>
      (a.lat - b.lat).abs() < 1e-5 && (a.lon - b.lon).abs() < 1e-5;

  Place? favouriteAt(Place place) {
    for (final f in favourites) {
      if (samePlace(f, place)) return f;
    }
    return null;
  }

  void saveFavourite(Place place) {
    update((s) {
      s.favourites.removeWhere((f) => samePlace(f, place));
      s.favourites.insert(0, place);
    });
  }

  void removeFavourite(Place place) {
    update((s) => s.favourites.removeWhere((f) => samePlace(f, place)));
  }

  /// Night colours between 18:30 and 05:30 when theme is auto.
  bool get isNight {
    switch (theme) {
      case ThemeChoice.day:
        return false;
      case ThemeChoice.night:
        return true;
      case ThemeChoice.auto:
        final now = DateTime.now();
        final mins = now.hour * 60 + now.minute;
        return mins >= 18 * 60 + 30 || mins < 5 * 60 + 30;
    }
  }
}
