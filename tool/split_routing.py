"""Splits the Valhalla routing tiles for South Africa into one zip per
province, so the phone only downloads what it needs.

Usage: python3 tool/split_routing.py <tile_dir> <out_dir>
Writes <out_dir>/route-<id>.zip. Inside, files keep their Valhalla paths
(e.g. 2/000/756/425.gph) so the app can unpack them into one tile folder.
"""
import os
import sys
import zipfile

sys.path.insert(0, os.path.dirname(__file__))
from provinces import PROVINCES, overlaps  # noqa: E402

TILE_SIZE = {0: 4.0, 1: 1.0, 2: 0.25}
MARGIN = 0.3  # degrees: include roads just over the border


def tile_box(path):
    """west,south,east,north of a tile from its path, e.g. 2/000/756/425.gph."""
    parts = path.replace("\\", "/").split("/")
    level = int(parts[0])
    tid = int("".join(parts[1:]).replace(".gph", ""))
    size = TILE_SIZE[level]
    cols = int(360 / size)
    row, col = divmod(tid, cols)
    w = -180 + col * size
    s = -90 + row * size
    return [w, s, w + size, s + size]


tile_dir, out_dir = sys.argv[1], sys.argv[2]
os.makedirs(out_dir, exist_ok=True)
tiles = []
for root, _, files in os.walk(tile_dir):
    for f in files:
        if f.endswith(".gph"):
            rel = os.path.relpath(os.path.join(root, f), tile_dir)
            if rel.split(os.sep)[0] in ("0", "1", "2"):
                tiles.append((rel, tile_box(rel)))
print(f"{len(tiles)} routing tiles")

for pid, name, b in PROVINCES:
    box = [b[0] - MARGIN, b[1] - MARGIN, b[2] + MARGIN, b[3] + MARGIN]
    chosen = [rel for rel, tb in tiles if overlaps(tb, box)]
    out = os.path.join(out_dir, f"route-{pid}.zip")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for rel in chosen:
            z.write(os.path.join(tile_dir, rel), rel.replace(os.sep, "/"))
    print(f"{name}: {len(chosen)} tiles, {os.path.getsize(out) / 1e6:.0f} MB")
