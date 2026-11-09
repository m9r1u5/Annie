// Central settings for SafeRoute SA.
// Change githubOwner / githubRepo if your repo has a different name.

class AppConfig {
  static const appName = 'SafeRoute SA';

  static const githubOwner = 'm9r1u5';
  static const githubRepo = 'annie';

  /// Release that the weekly "Build map packs" workflow fills with map files.
  static const mapsReleaseTag = 'maps-latest';

  static String get mapsBaseUrl =>
      'https://github.com/$githubOwner/$githubRepo/releases/download/$mapsReleaseTag';

  static String get releasesPage =>
      'https://github.com/$githubOwner/$githubRepo/releases';

  static String get releasesApi =>
      'https://api.github.com/repos/$githubOwner/$githubRepo/releases?per_page=15';

  /// Free public Valhalla routing server run by FOSSGIS (fair use).
  static const valhallaUrl = 'https://valhalla1.openstreetmap.de/route';

  /// Free public Photon address search by Komoot (fair use).
  static const photonUrl = 'https://photon.komoot.io/api/';

  /// Online map used until a province pack is downloaded.
  static const onlineStyleUrl = 'https://tiles.openfreemap.org/styles/liberty';

  /// South Africa bounding box: west, south, east, north.
  static const saBbox = [16.3, -35.0, 33.0, -22.0];

  /// Map opens on Johannesburg before a GPS fix arrives.
  static const defaultLat = -26.2041;
  static const defaultLon = 28.0473;

  static const userAgent = 'SafeRouteSA/1.0 (github.com/m9r1u5/annie)';
}
