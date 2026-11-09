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

# id, name, bbox (west, south, east, north) - a little wider than each province
PROVINCES = [
    ("gauteng", "Gauteng", [27.10, -26.95, 29.10, -25.05]),
    ("western-cape", "Western Cape", [17.70, -34.90, 24.30, -30.90]),
    ("eastern-cape", "Eastern Cape", [22.50, -34.30, 30.30, -30.00]),
    ("kwazulu-natal", "KwaZulu-Natal", [28.80, -31.20, 33.00, -26.70]),
    ("free-state", "Free State", [24.30, -30.80, 29.90, -26.55]),
    ("north-west", "North West", [22.60, -28.00, 28.40, -24.60]),
    ("mpumalanga", "Mpumalanga", [28.10, -27.90, 32.10, -24.00]),
    ("limpopo", "Limpopo", [26.30, -25.50, 31.95, -22.10]),
    ("northern-cape", "Northern Cape", [16.40, -32.90, 25.60, -24.70]),
]

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
    packs.append({
        "id": pid,
        "name": name,
        "file": f"{pid}.pmtiles",
        "size": os.path.getsize(out_file),
        "bbox": bbox,
    })

assets = f"{OUT}/map-assets.zip"
manifest = {
    "version": BUILD,
    "built": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "source": "Protomaps daily build of OpenStreetMap",
    "packs": packs,
    "assets": {"file": "map-assets.zip", "size": os.path.getsize(assets)},
}
with open(f"{OUT}/manifest.json", "w") as f:
    json.dump(manifest, f, indent=2)
print(json.dumps(manifest, indent=2))
