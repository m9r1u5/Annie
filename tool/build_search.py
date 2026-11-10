"""Builds one offline search database per province from OpenStreetMap.

Usage: python3 tool/build_search.py <filtered.osm.pbf> <out_dir>
Writes <out_dir>/search-<id>.db (SQLite, full-text table "s").

Rows: places (cities, towns, suburbs), points of interest (shops, fuel,
hospitals, schools, ...), streets, and street addresses (house numbers).
Each row has a "context" like "Sandton, Johannesburg" so results are clear.
"""
import math
import os
import sqlite3
import sys
from collections import defaultdict

import osmium

sys.path.insert(0, os.path.dirname(__file__))
from provinces import PROVINCES  # noqa: E402

PLACE_RANK = {"city": 1, "town": 2, "suburb": 3, "village": 3, "quarter": 4,
              "neighbourhood": 4, "hamlet": 5, "locality": 6, "township": 3}
POI_KEYS = ("amenity", "shop", "tourism", "leisure", "office", "healthcare",
            "aeroway", "railway", "public_transport", "historic", "sport", "craft")
SKIP_POI = {"bench", "waste_basket", "parking_space", "toilets", "drinking_water",
            "post_box", "vending_machine", "bicycle_parking", "telephone"}


class Collector(osmium.SimpleHandler):
    def __init__(self):
        super().__init__()
        self.places = []  # (name, kind, lat, lon)
        self.pois = []    # (name, kind, lat, lon, street)
        self.streets = {}  # (name, cell) -> (lat, lon)
        self.addrs = []   # (number, street, lat, lon)

    def _add(self, tags, lat, lon):
        name = tags.get("name")
        place = tags.get("place")
        if name and place in PLACE_RANK:
            self.places.append((name, place, lat, lon))
            return
        hn, st = tags.get("addr:housenumber"), tags.get("addr:street")
        if name:
            for k in POI_KEYS:
                v = tags.get(k)
                if v and v not in SKIP_POI:
                    self.pois.append((name, v.replace("_", " "), lat, lon, st or ""))
                    return
        if hn and st:
            self.addrs.append((hn, st, lat, lon))

    def node(self, n):
        if len(n.tags) == 0 or not n.location.valid():
            return
        self._add(n.tags, n.location.lat, n.location.lon)

    def way(self, w):
        tags = w.tags
        try:
            pts = [(nd.lat, nd.lon) for nd in w.nodes if nd.location.valid()]
        except osmium.InvalidLocationError:
            return
        if not pts:
            return
        lat = sum(p[0] for p in pts) / len(pts)
        lon = sum(p[1] for p in pts) / len(pts)
        hw, name = tags.get("highway"), tags.get("name")
        if hw and name and hw not in ("footway", "path", "cycleway", "steps", "bridleway", "track"):
            # One row per street per ~1 km cell (streets are split into many pieces).
            mid = pts[len(pts) // 2]
            key = (name, round(mid[0] / 0.01), round(mid[1] / 0.01))
            if key not in self.streets:
                self.streets[key] = mid
            return
        self._add(tags, lat, lon)


def main():
    src, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)
    c = Collector()
    c.apply_file(src, locations=True, idx="flex_mem")
    print(f"places {len(c.places)}, pois {len(c.pois)}, streets {len(c.streets)}, "
          f"addresses {len(c.addrs)}", flush=True)

    # Grid of places for "Suburb, Town" context.
    grid = defaultdict(list)
    for name, kind, lat, lon in c.places:
        grid[(int(math.floor(lat * 5)), int(math.floor(lon * 5)))].append((name, kind, lat, lon))

    def near(lat, lon, kinds, max_km):
        best, bd = None, max_km
        gy, gx = int(math.floor(lat * 5)), int(math.floor(lon * 5))
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                for name, kind, plat, plon in grid.get((gy + dy, gx + dx), ()):
                    if kind not in kinds:
                        continue
                    d = math.hypot((plat - lat) * 111, (plon - lon) * 111 * math.cos(math.radians(lat)))
                    if d < bd:
                        best, bd = name, d
        return best

    def context(lat, lon, extra=""):
        sub = near(lat, lon, {"suburb", "neighbourhood", "quarter", "township"}, 4)
        town = near(lat, lon, {"city", "town", "village"}, 20)
        parts = [p for p in (extra, sub, town) if p]
        out = []
        for p in parts:
            if p not in out:
                out.append(p)
        return ", ".join(out)

    rows = []  # name, context, kind, lat, lon, rank
    for name, kind, lat, lon in c.places:
        town = near(lat, lon, {"city", "town"}, 30) if kind not in ("city", "town") else None
        rows.append((name, town if town and town != name else "", kind, lat, lon, PLACE_RANK[kind]))
    for name, kind, lat, lon, st in c.pois:
        rows.append((name, context(lat, lon, st), kind, lat, lon, 5))
    for (name, _, _), (lat, lon) in c.streets.items():
        rows.append((name, context(lat, lon), "street", lat, lon, 6))
    for hn, st, lat, lon in c.addrs:
        rows.append((f"{hn} {st}", context(lat, lon), "address", lat, lon, 7))
    print(f"{len(rows)} search rows", flush=True)

    for pid, pname, (w, s, e, n) in PROVINCES:
        path = os.path.join(out_dir, f"search-{pid}.db")
        if os.path.exists(path):
            os.remove(path)
        db = sqlite3.connect(path)
        db.execute("CREATE VIRTUAL TABLE s USING fts4(name, context, kind, lat, lon, rank, "
                   "notindexed=kind, notindexed=lat, notindexed=lon, notindexed=rank, "
                   "tokenize=unicode61)")
        mine = [r for r in rows if w <= r[4] <= e and s <= r[3] <= n]
        db.executemany("INSERT INTO s VALUES (?,?,?,?,?,?)", mine)
        db.execute("INSERT INTO s(s) VALUES('optimize')")
        db.commit()
        db.execute("VACUUM")
        db.close()
        print(f"{pname}: {len(mine)} rows, {os.path.getsize(path) / 1e6:.0f} MB", flush=True)


if __name__ == "__main__":
    main()
