# /// script
# requires-python = ">=3.10"
# ///
"""从高德 POI 搜索导入连云港市警务工作站/警务站，生成幂等种子 SQL。

用法：

    AMAP_KEY=<高德服务Key> PGPASSWORD=postgres uv run scripts/import_amap_police_stations.py \
        --dsn postgresql://postgres@10.1.109.151:5432/huaguoshan_projd \
        --output backend/seed_police_station_amap.sql

处理流程：
1. 调用高德 Web 服务「关键字搜索 POI 2.0」接口（city=连云港, citylimit=true），
   分别检索『警务工作站』与『警务站』，按 id 去重后仅保留名称含『警务站』的 POI；
2. 高德返回坐标为 GCJ-02，按 coordtransform 近似算法纠偏为 WGS84 写入 EPSG:4326；
3. 读取库内 emergency_resource.police_station 现有记录，按「名称核心子串 ≥3 字
   且距离 <500 米」做实体对齐：
   - 命中：仅合并 metadata（追加 sources 与 amap 来源快照），不改坐标；
   - 未命中：以 source_code = AMAP-<id> 生成新行（幂等 upsert）。
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

AMAP_TEXT_SEARCH_URL = "https://restapi.amap.com/v3/place/text"
KEYWORDS = ("警务工作站", "警务站")
MATCH_MAX_DISTANCE_M = 500.0
# 名称对齐时剔除的通用词，剩余部分称为“名称核心”
GENERIC_TOKENS = (
    "连云港市",
    "江苏省",
    "公安分局",
    "公安局",
    "公安",
    "警务工作站",
    "警务站",
    "服务区",
    "派出所",
    "110",
    "-",
    " ",
)
UNIT_MARKERS = ("公安分局", "公安局", "派出所", "大队")

PI = 3.1415926535897932384626
EARTH_SEMIMAJOR_AXIS = 6378245.0
ECCENTRICITY_SQUARED = 0.00669342162296594323


# -----------------------------------------------------------------------------
# GCJ-02 -> WGS84（与 geocoding 技能一致的 coordtransform 近似算法）
# -----------------------------------------------------------------------------
def _transform_latitude(longitude: float, latitude: float) -> float:
    result = (
        -100.0
        + 2.0 * longitude
        + 3.0 * latitude
        + 0.2 * latitude * latitude
        + 0.1 * longitude * latitude
        + 0.2 * math.sqrt(abs(longitude))
    )
    result += (
        20.0 * math.sin(6.0 * longitude * PI) + 20.0 * math.sin(2.0 * longitude * PI)
    ) * 2.0 / 3.0
    result += (
        20.0 * math.sin(latitude * PI) + 40.0 * math.sin(latitude / 3.0 * PI)
    ) * 2.0 / 3.0
    result += (
        160.0 * math.sin(latitude / 12.0 * PI) + 320.0 * math.sin(latitude * PI / 30.0)
    ) * 2.0 / 3.0
    return result


def _transform_longitude(longitude: float, latitude: float) -> float:
    result = (
        300.0
        + longitude
        + 2.0 * latitude
        + 0.1 * longitude * longitude
        + 0.1 * longitude * latitude
        + 0.1 * math.sqrt(abs(longitude))
    )
    result += (
        20.0 * math.sin(6.0 * longitude * PI) + 20.0 * math.sin(2.0 * longitude * PI)
    ) * 2.0 / 3.0
    result += (
        20.0 * math.sin(longitude * PI) + 40.0 * math.sin(longitude / 3.0 * PI)
    ) * 2.0 / 3.0
    result += (
        150.0 * math.sin(longitude / 12.0 * PI) + 300.0 * math.sin(longitude / 30.0 * PI)
    ) * 2.0 / 3.0
    return result


def gcj02_to_wgs84(longitude: float, latitude: float) -> tuple[float, float]:
    if not (73.66 < longitude < 135.05 and 3.86 < latitude < 53.55):
        return longitude, latitude
    delta_latitude = _transform_latitude(longitude - 105.0, latitude - 35.0)
    delta_longitude = _transform_longitude(longitude - 105.0, latitude - 35.0)
    radians_latitude = latitude / 180.0 * PI
    magic = math.sin(radians_latitude)
    magic = 1 - ECCENTRICITY_SQUARED * magic * magic
    square_root_magic = math.sqrt(magic)
    delta_latitude = (delta_latitude * 180.0) / (
        (EARTH_SEMIMAJOR_AXIS * (1 - ECCENTRICITY_SQUARED))
        / (magic * square_root_magic)
        * PI
    )
    delta_longitude = (delta_longitude * 180.0) / (
        EARTH_SEMIMAJOR_AXIS / square_root_magic * math.cos(radians_latitude) * PI
    )
    return longitude - delta_longitude, latitude - delta_latitude


# -----------------------------------------------------------------------------
# 高德抓取
# -----------------------------------------------------------------------------
def amap_search(key: str, keyword: str, page: int) -> dict:
    query = urllib.parse.urlencode(
        {
            "key": key,
            "keywords": keyword,
            "city": "连云港",
            "citylimit": "true",
            "offset": 25,
            "page": page,
            "extensions": "all",
        }
    )
    request = urllib.request.Request(
        f"{AMAP_TEXT_SEARCH_URL}?{query}", headers={"User-Agent": "huaguoshan-poi-import/1.0"}
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.loads(response.read().decode("utf-8"))


def fetch_all(key: str) -> dict[str, dict]:
    pois: dict[str, dict] = {}
    for keyword in KEYWORDS:
        page = 1
        while True:
            payload = amap_search(key, keyword, page)
            if payload.get("infocode") != "10000":
                raise RuntimeError(f"高德接口错误: {payload}")
            items = payload.get("pois") or []
            if page == 1:
                print(f"[{keyword}] 高德报告总数={payload.get('count')}", file=sys.stderr)
            for item in items:
                if "警务站" not in item.get("name", "") and "警务工作站" not in item.get("name", ""):
                    continue  # 关键字会被模糊分词，只保留名称实际命中的
                item["_keyword"] = keyword
                pois[item["id"]] = item
            if len(items) < 25:
                break
            page += 1
            time.sleep(0.3)
    return pois


# -----------------------------------------------------------------------------
# 库内现有记录（通过 psql 读取，避免引入 Python PG 驱动依赖）
# -----------------------------------------------------------------------------
def fetch_existing(dsn: str) -> list[dict]:
    sql = (
        "select source_code, name, station_type, county_name, "
        "ST_X(geom), ST_Y(geom) "
        "from emergency_resource.police_station order by id"
    )
    result = subprocess.run(
        ["psql", dsn, "-v", "ON_ERROR_STOP=1", "-At", "-F", "\t", "-c", sql],
        check=True,
        capture_output=True,
        text=True,
    )
    rows = []
    for line in result.stdout.splitlines():
        source_code, name, station_type, county_name, lon, lat = line.split("\t")
        rows.append(
            {
                "source_code": source_code,
                "name": name,
                "station_type": station_type,
                "county_name": county_name or None,
                "lon": float(lon),
                "lat": float(lat),
            }
        )
    return rows


# -----------------------------------------------------------------------------
# 实体对齐
# -----------------------------------------------------------------------------
def name_core(name: str) -> str:
    core = name
    for token in GENERIC_TOKENS:
        core = core.replace(token, "")
    return core


def longest_common_substring(a: str, b: str) -> int:
    if not a or not b:
        return 0
    previous = [0] * (len(b) + 1)
    best = 0
    for i in range(1, len(a) + 1):
        current = [0] * (len(b) + 1)
        for j in range(1, len(b) + 1):
            if a[i - 1] == b[j - 1]:
                current[j] = previous[j - 1] + 1
                best = max(best, current[j])
        previous = current
    return best


def distance_m(lon1: float, lat1: float, lon2: float, lat2: float) -> float:
    return math.hypot((lon1 - lon2) * 95.0, (lat1 - lat2) * 111.0) * 1000.0


def find_match(amap_name: str, lon: float, lat: float, existing: list[dict]) -> dict | None:
    core = name_core(amap_name)
    best: tuple[float, dict] | None = None
    for row in existing:
        dist = distance_m(lon, lat, row["lon"], row["lat"])
        if dist >= MATCH_MAX_DISTANCE_M:
            continue
        other_core = name_core(row["name"])
        name_hit = longest_common_substring(core, other_core) >= 3 or (
            core == other_core and len(core) >= 2
        )
        if not name_hit:
            continue
        if best is None or dist < best[0]:
            best = (dist, row)
    return best[1] if best else None


# -----------------------------------------------------------------------------
# SQL 生成
# -----------------------------------------------------------------------------
def esc(value: str | None) -> str:
    if value is None:
        return "null"
    return "'" + value.replace("'", "''") + "'"


def managing_unit(name: str) -> str | None:
    best = None
    for marker in UNIT_MARKERS:
        index = name.rfind(marker)
        if index > 0 and (best is None or index + len(marker) > best):
            best = index + len(marker)
    return name[:best] if best else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key", default=os.environ.get("AMAP_KEY"), help="高德服务 Key（或环境变量 AMAP_KEY）")
    parser.add_argument("--dsn", required=True, help="PostgreSQL DSN（读取库内现有警务站记录用于实体对齐）")
    parser.add_argument("--output", required=True, help="生成的种子 SQL 输出路径")
    args = parser.parse_args()
    if not args.key:
        parser.error("缺少高德 Key：请传 --key 或设置环境变量 AMAP_KEY")

    pois = fetch_all(args.key)
    print(f"高德名称命中去重后共 {len(pois)} 个 POI", file=sys.stderr)

    existing = fetch_existing(args.dsn)
    print(f"库内现有警务站记录 {len(existing)} 条", file=sys.stderr)

    updates: list[str] = []
    inserts: list[str] = []
    matched_count = 0
    for poi in sorted(pois.values(), key=lambda p: (p.get("adname", ""), p["name"])):
        name = poi["name"]
        gcj_lon, gcj_lat = (float(v) for v in poi["location"].split(","))
        lon, lat = gcj02_to_wgs84(gcj_lon, gcj_lat)
        lon, lat = round(lon, 6), round(lat, 6)
        address = poi.get("address") if isinstance(poi.get("address"), str) and poi.get("address") else None
        tel = poi.get("tel") if isinstance(poi.get("tel"), str) and poi.get("tel") else None
        county = poi.get("adname") or None

        hit = find_match(name, lon, lat, existing)
        if hit:
            matched_count += 1
            merged_meta = {
                "sources": ["tianditu", "amap"],
                "amap": {
                    "id": poi["id"],
                    "name": name,
                    "address": address,
                    "gcj02": [gcj_lon, gcj_lat],
                    "wgs84": [lon, lat],
                },
            }
            updates.append(
                f"update emergency_resource.police_station\n"
                f"set metadata = metadata || {esc(json.dumps(merged_meta, ensure_ascii=False))}::jsonb\n"
                f"where source_code = {esc(hit['source_code'])};"
            )
            print(f"  对齐: {name} -> {hit['source_code']} ({hit['name']})", file=sys.stderr)
            continue

        station_type = "workstation" if "警务工作站" in name else "station"
        meta = {
            "provider": "amap",
            "amapId": poi["id"],
            "keyword": poi["_keyword"],
            "sources": ["amap"],
            "sourceCoordinates": {
                "longitude": gcj_lon,
                "latitude": gcj_lat,
                "coordinateSystem": "GCJ-02",
            },
            "coordinateConversion": "GCJ-02 -> WGS84 (coordtransform)",
        }
        inserts.append(
            "  (%s, %s, %s, %s, %s, %s, %s, 'unknown', false, %s::jsonb, ST_SetSRID(ST_MakePoint(%s, %s), 4326))"
            % (
                esc("AMAP-" + poi["id"]),
                esc(name),
                esc(station_type),
                esc(managing_unit(name)),
                esc(tel),
                esc(address),
                esc(county),
                esc(json.dumps(meta, ensure_ascii=False)),
                repr(lon),
                repr(lat),
            )
        )

    lines = [
        "-- 连云港市警务工作站/警务站真实 POI 数据导入（高德来源）。",
        "--",
        "-- 来源：高德 Web 服务 POI 关键字搜索（city=连云港, citylimit=true），",
        "-- 关键字『警务工作站』与『警务站』，按名称命中过滤并与库内天地图记录做实体对齐。",
        "-- 坐标：高德 GCJ-02 已按 coordtransform 近似算法纠偏为 WGS84，写入 EPSG:4326 Point。",
        "-- 幂等：新记录以 source_code = 'AMAP-' || 高德POI id 为冲突键；",
        "-- 已对齐的天地图记录仅合并 metadata（sources、amap 快照），可重复执行。",
        "-- 生成脚本：scripts/import_amap_police_stations.py",
        "",
        "begin;",
        "",
    ]
    if updates:
        lines.append("-- 与库内天地图记录对齐：合并 metadata")
        lines.extend(updates)
        lines.append("")
    if inserts:
        lines.append("-- 高德独有点位：新增记录")
        lines.append("insert into emergency_resource.police_station (")
        lines.append("  source_code, name, station_type, managing_unit_name, contact_phone, address, county_name,")
        lines.append("  availability_status, is_simulated, metadata, geom")
        lines.append(") values")
        lines.append(",\n".join(inserts))
        lines.append("on conflict (source_code) do update set")
        lines.append("  name = excluded.name,")
        lines.append("  station_type = excluded.station_type,")
        lines.append("  managing_unit_name = excluded.managing_unit_name,")
        lines.append("  contact_phone = excluded.contact_phone,")
        lines.append("  address = excluded.address,")
        lines.append("  county_name = excluded.county_name,")
        lines.append("  metadata = excluded.metadata,")
        lines.append("  geom = excluded.geom,")
        lines.append("  is_simulated = false;")
        lines.append("")
    lines.append("commit;")
    lines.append("")

    with open(args.output, "w", encoding="utf-8") as fp:
        fp.write("\n".join(lines))

    print(
        f"完成：对齐合并 {matched_count} 条，新增 {len(inserts)} 条，SQL 已写入 {args.output}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
