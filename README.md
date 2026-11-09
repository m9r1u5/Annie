# SafeRoute SA

Turn-by-turn navigation for South Africa. Flutter app, Android first (iOS in Phase 5).

**Phase 1 (this version):** map (2D/3D), offline province maps with Wi-Fi-only
downloads and weekly updates, address search, routing, English/Afrikaans voice
directions, driving screen, share ETA, update and share buttons.

---

## Set it up from your phone (once)

1. **Create the repo.** On github.com tap **+ → New repository**.
   Name it `SafeRoute-SA`, choose **Public**, tick **Add a README file**, tap **Create**.
   (Public is needed so the app can download maps and updates without a login.)

2. **Add the signing password.** In the repo: **Settings → Secrets and variables →
   Actions → New repository secret**.
   Name: `KEYSTORE_PASSWORD` · Value: the password from `KEYSTORE_PASSWORD.txt`.
   Keep that password safe. Every future update must be signed with it, or phones
   will refuse to install the update over the old app.

3. **Add the two workflow files** (GitHub won't let a workflow create these, so
   they're done by hand). In the repo tap **Add file → Create new file**:
   - Name: `.github/workflows/build.yml` → paste the contents of `build.yml` → **Commit**.
   - Again with name `.github/workflows/maps.yml` → paste `maps.yml` → **Commit**.
   The first build will fail with "No app code yet". That's expected.

4. **Upload the app code.** **Add file → Upload files** → choose `SafeRoute-SA.zip`
   → **Commit**. The build unpacks the zip, saves the files and builds the APK
   (about 10–15 minutes; watch the **Actions** tab).

5. **Build the offline maps.** **Actions → Build map packs → Run workflow**.
   The first run takes 1–3 hours. After that it runs by itself every Monday at 02:17.

6. **Install.** Open **Releases** → newest `v1.0.x` → tap `SafeRoute-SA.apk`.
   Allow your browser to install apps when Android asks.

7. **In the app:** tap the download icon (top right), pick your province, tap
   **Download**. With Wi-Fi only on, it waits for Wi-Fi.

## Changing the app later

Edit files on GitHub (or upload a new zip). Every commit builds a new
`v1.0.N` release. In the app, **Settings → Update app** finds it.

---

## How it works

| Part | What it uses | Cost / limits |
|---|---|---|
| Map display | MapLibre (2D/3D, vector maps) | Free, open source |
| Offline maps | One file per province, cut weekly from Protomaps' OpenStreetMap build by `maps.yml`, stored as GitHub release files | Free. GitHub allows up to 2 GB per file |
| Map before download | OpenFreeMap online map | Free, no key. Its own offline limit is small, so offline uses our packs |
| Routing | Valhalla, public FOSSGIS server | Free, fair use. Fine for you and testers; with many users, run your own Valhalla server |
| Search | Photon (Komoot) | Free, fair use; needs data |
| Voice | Phone's built-in text-to-speech | Free, offline |
| Builds | GitHub Actions | Free and unlimited for public repos |

**Why Valhalla over GraphHopper:** Valhalla takes avoid areas directly in each
route request (`exclude_polygons`), which is exactly what Phase 2 safety zones
need. It also has toll, highway and gravel options, its public server is free,
and it can later run on the phone itself for fully offline routing.
GraphHopper's hosted API needs a paid key above a small free quota, and its
Android offline version is no longer maintained.

### What works offline right now

- **Offline:** the map itself (downloaded provinces), your location, voice
  directions, following a route you already started, saved places, typing
  coordinates.
- **Needs data (very little):** search and calculating a route or a re-route.
  A route request is a few KB.

Fully offline routing and search come in a later phase: `maps.yml` will also
build Valhalla routing data and a search index per province, and the app will
run Valhalla on the phone.

---

## Sign-ups you'll need, and when

| When | What | Where |
|---|---|---|
| Phase 1 (now) | Nothing | — |
| Phase 3 (live traffic) | Free TomTom developer key | developer.tomtom.com → sign up → Dashboard → copy key. You paste it into the app's Settings |
| Phase 4 (crowd reports, hotspots) | Free Firebase project (Spark plan) | console.firebase.google.com |
| Phase 5 (iPhone) | Apple Developer account (paid yearly) and a Mac build runner | developer.apple.com |
| Play Store (optional) | Google Play developer account (once-off fee) | play.google.com/console |

## Credits

Map data © OpenStreetMap contributors (ODbL). Map tiles: Protomaps and
OpenFreeMap / OpenMapTiles. Routing: Valhalla. Search: Photon.
