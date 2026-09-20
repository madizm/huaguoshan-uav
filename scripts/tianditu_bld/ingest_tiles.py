# /// script
# requires-python = ">=3.10"
# dependencies = ["mapbox-vector-tile", "shapely", "psycopg[binary]"]
# ///
"""天地图江苏建筑瓦片解码入库：MVT → raw.tianditu_bld_fragment → 重组。

瓦片内坐标（extent 4096，y 向下）转经纬度：
  lon = -180 + (x + vx/4096) * span
  lat = -90 + (y + 1) * span - (vy/4096) * span   # MVT y 轴向下，瓦片北缘为上界

用法：
  uv run scripts/tianditu_bld/ingest_tiles.py
  uv run scripts/tianditu_bld/ingest_tiles.py --dry-run
"""
import argparse
import os
import re
from pathlib import Path

import mapbox_vector_tile
import psycopg
from shapely.geometry import Polygon
from shapely.wkb import dumps as wkb_dumps

CACHE_DIR = Path(__file__).resolve().parents[2] / "data" / "tianditu-bld"
DB_DSN = os.environ.get(
    "DATABASE_URL",
    "postgresql://postgres:postgres@10.1.109.151:5432/huaguoshan_projd",
)


def parse_floor(value) -> int | None:
    if value is None:
        return None
    m = re.match(r"^\s*(\d{1,3})", str(value))
    return int(m.group(1)) if m else None


def tile_transformer(z: int, x: int, y: int, extent: int = 4096):
    span = 360.0 / 2**z
    lon0 = -180 + x * span
    lat_top = -90 + (y + 1) * span

    def to_lonlat(vx: float, vy: float) -> tuple[float, float]:
        return lon0 + (vx / extent) * span, lat_top - (vy / extent) * span

    return to_lonlat


def transform_geometry(geom: dict, to_lonlat) -> list[Polygon]:
    """GeoJSON 风格的瓦片坐标几何 → EPSG:4326 Polygon 列表。"""
    polys = []
    coords_list = []
    if geom["type"] == "Polygon":
        coords_list = [geom["coordinates"]]
    elif geom["type"] == "MultiPolygon":
        coords_list = geom["coordinates"]
    for rings in coords_list:
        if not rings:
            continue
        exterior = [to_lonlat(px, py) for px, py in rings[0]]
        holes = [[to_lonlat(px, py) for px, py in ring] for ring in rings[1:]]
        poly = Polygon(exterior, holes)
        if poly.is_valid and not poly.is_empty:
            polys.append(poly)
    return polys


def iter_tiles():
    for pbf in sorted(CACHE_DIR.rglob("*.pbf")):
        z, x = int(pbf.parent.parent.name), int(pbf.parent.name)
        y = int(pbf.stem)
        yield z, x, y, pbf


def main() -> None:
    parser = argparse.ArgumentParser(description="解码建筑瓦片并入库")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    rows = []
    for z, x, y, pbf in iter_tiles():
        tile = mapbox_vector_tile.decode(pbf.read_bytes())
        layer = tile.get("BLD")
        if not layer:
            continue
        to_lonlat = tile_transformer(z, x, y, layer.get("extent", 4096))
        for feature in layer["features"]:
            elemid = feature["properties"].get("ELEMID")
            if not elemid:
                continue
            floor_num = parse_floor(feature["properties"].get("FLOOR"))
            for poly in transform_geometry(feature["geometry"], to_lonlat):
                rows.append((elemid, z, x, y, floor_num, wkb_dumps(poly)))

    print(f"解码碎片 {len(rows)} 条，涉及建筑 {len({r[0] for r in rows})} 个")
    if args.dry_run or not rows:
        return

    with psycopg.connect(DB_DSN) as conn:
        with conn.cursor() as cur:
            cur.executemany(
                """
                insert into raw.tianditu_bld_fragment (elemid, z, x, y, floor_num, geom)
                values (%s, %s, %s, %s, %s, ST_GeomFromWKB(%s, 4326))
                on conflict (elemid, z, x, y) do nothing
                """,
                rows,
            )
            cur.execute("select raw.rebuild_tianditu_bld_features()")
            rebuilt = cur.fetchone()[0]
        conn.commit()
    print(f"入库完成，重组建筑 {rebuilt} 个")


if __name__ == "__main__":
    main()
