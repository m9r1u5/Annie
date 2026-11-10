"""Cuts one offline map file per South African province out of the latest
Protomaps OpenStreetMap build, then writes manifest.json for the app.

Run by .github/workflows/maps.yml. Needs the `pmtiles` command and
out/map-assets.zip (fonts, icons, style layers) made in an earlier step.
"""
import json
import os
import subprocess
from datetime import datetime, timezone

BUILD = os.environ["PROTOMAPS_BUILD"]  # e.g. 20261108
SOURCE = f"https://build.protomaps.com/{BUILD}.pmtiles"
OUT = "out"
MAXZOOM = "15"

import sys

sys.path.insert(0, os.path.dirname(__file__))
from provinces import PROVINCES  # noqa: E402

os.makedirs(OUT, exist_ok=True)

packs = []
for pid, name, bbox in PROVINCES:
    out_file = f"{OUT}/{pid}.pmtiles"
    print(f"== {name}", flush=True)
    subprocess.run(
        [
            "pmtiles", "extract", SOURCE, out_file,
            "--bbox=" + ",".join(str(v) for v in bbox),
            "--maxzoom=" + MAXZOOM,
        ],
        check=True,
    )
    pack = {
        "id": pid,
        "name": name,
        "file": f"{pid}.pmtiles",
        "size": os.path.getsize(out_file),
        "bbox": bbox,
    }
    # Offline routing and search, if those steps worked.
    route = f"{OUT}/route-{pid}.zip"
    if os.path.exists(route):
        pack["route_file"] = os.path.basename(route)
        pack["route_size"] = os.path.getsize(route)
    search = f"{OUT}/search-{pid}.db"
    if os.path.exists(search):
        pack["search_file"] = os.path.basename(search)
        pack["search_size"] = os.path.getsize(search)
    packs.append(pack)

assets = f"{OUT}/map-assets.zip"
manifest = {
    "version": BUILD,
    "built": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "source": "Protomaps daily build of OpenStreetMap; routing and search from Geofabrik OSM extract",
    "packs": packs,
    "assets": {"file": "map-assets.zip", "size": os.path.getsize(assets)},
}
with open(f"{OUT}/manifest.json", "w") as f:
    json.dump(manifest, f, indent=2)
print(json.dumps(manifest, indent=2))
