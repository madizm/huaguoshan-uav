# /// script
# requires-python = ">=3.10"
# dependencies = ["httpx"]
# ///
"""天地图江苏 tdtjs:BLD 矢量瓦片下载器。

网格定义见 docs/tianditu_bld_whitemodel_3dtiles_plan.md：
span(z) = 360°/2^z，全局原点 (-180,-90)，TMS y 轴自南向北。

用法：
  uv run scripts/tianditu_bld/download_tiles.py --bbox 119.15,34.60,119.35,34.72
  uv run scripts/tianditu_bld/download_tiles.py --tile 54466,22680
"""
import argparse
import math
import time
from pathlib import Path

import httpx

BASE_URL = (
    "https://jiangsu.tianditu.gov.cn/jsgeo/geoserver/gwc/service/tms/1.0.0/"
    "tdtjs%3ABLD@tdt_EPSG_4490_grid@pbf/{z}/{x}/{y}.pbf"
)
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                  "(KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36",
    "Referer": "https://jiangsu.tianditu.gov.cn/jsmap/index.html",
}
CACHE_DIR = Path(__file__).resolve().parents[2] / "data" / "tianditu-bld"


def lonlat_to_tile(lon: float, lat: float, z: int) -> tuple[int, int]:
    span = 360.0 / 2**z
    return math.floor((lon + 180) / span), math.floor((lat + 90) / span)


def bbox_tiles(lon0: float, lat0: float, lon1: float, lat1: float, z: int):
    x0, y0 = lonlat_to_tile(lon0, lat0, z)
    x1, y1 = lonlat_to_tile(lon1, lat1, z)
    for x in range(min(x0, x1), max(x0, x1) + 1):
        for y in range(min(y0, y1), max(y0, y1) + 1):
            yield x, y


def download(client: httpx.Client, z: int, x: int, y: int) -> str:
    """下载单瓦片，返回状态：cached / ok / empty / failed。"""
    path = CACHE_DIR / str(z) / str(x) / f"{y}.pbf"
    if path.exists():
        return "cached"
    if path.with_suffix(".empty").exists():
        return "cached"
    url = BASE_URL.format(z=z, x=x, y=y)
    for attempt in range(3):
        try:
            resp = client.get(url, headers=HEADERS, timeout=30)
            if resp.status_code == 200 and len(resp.content) > 20:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(resp.content)
                return "ok"
            if resp.status_code in (204, 404) or len(resp.content) <= 20:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.with_suffix(".empty").touch()
                return "empty"
        except httpx.HTTPError:
            pass
        time.sleep(2**attempt)
    return "failed"


def main() -> None:
    parser = argparse.ArgumentParser(description="下载天地图江苏建筑矢量瓦片")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--bbox", help="lon0,lat0,lon1,lat1")
    group.add_argument("--tile", help="x,y 单瓦片")
    parser.add_argument("--zoom", type=int, default=16)
    parser.add_argument("--interval", type=float, default=0.15, help="请求间隔秒数")
    args = parser.parse_args()

    if args.tile:
        x, y = (int(v) for v in args.tile.split(","))
        tiles = [(x, y)]
    else:
        lon0, lat0, lon1, lat1 = (float(v) for v in args.bbox.split(","))
        tiles = list(bbox_tiles(lon0, lat0, lon1, lat1, args.zoom))

    stats = {"ok": 0, "cached": 0, "empty": 0, "failed": 0}
    with httpx.Client() as client:
        for i, (x, y) in enumerate(tiles, 1):
            status = download(client, args.zoom, x, y)
            stats[status] += 1
            if status in ("ok", "failed"):
                time.sleep(args.interval)
            if i % 100 == 0 or i == len(tiles):
                print(f"[{i}/{len(tiles)}] {stats}")
    print(f"完成：{stats}")


if __name__ == "__main__":
    main()
