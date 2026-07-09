#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "psycopg[binary]>=3.2",
#   "pyproj>=3.6",
#   "requests>=2.32",
#   "shapely>=2.0",
# ]
# ///
"""Import open DEM terrain data into PostGIS and 3DCityDB.

Default source is the public Copernicus DEM GLO-30 COG tile covering the original
Huaguoshan project area. For larger areas, pass ``--area-geojson`` and a local
mosaic/VRT through ``--source-file``. This is open DEM/DSM-derived elevation data,
not LiDAR, photogrammetry, or an authoritative 3D city model. The imported raster
is intended for approximate terrain elevation, building base-z adjustment, and
coarse UAV planning inputs.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence

import psycopg
import requests
from pyproj import Transformer
from shapely.geometry import mapping, shape
from shapely.geometry.base import BaseGeometry
from shapely.ops import transform as shapely_transform
from shapely.ops import unary_union


DEFAULT_DSN = "postgresql://postgres:postgres@10.1.109.151:5432/huaguoshan_projd"
TARGET_SRID = 32650
DATASET_KEY = "copernicus-dem-glo30-huaguoshan"
SOURCE_NAME = "Copernicus DEM GLO-30"
SOURCE_URL = "https://copernicus-dem-30m.s3.amazonaws.com/Copernicus_DSM_COG_10_N34_00_E119_00_DEM/Copernicus_DSM_COG_10_N34_00_E119_00_DEM.tif"
SOURCE_LICENSE = "Copernicus DEM license; verify current terms before redistribution"
SOURCE_VERSION = "GLO-30 public COG tile N34E119"
VERTICAL_DATUM = "Copernicus DEM vertical datum; record source metadata, do not mix with ellipsoidal heights"
RESOLUTION_M = 30.0
PROJECT_KEY = "huaguoshan"

AREA_GEOJSON = {
    "type": "Polygon",
    "coordinates": [[
        [119.23062143399773, 34.6640111299246],
        [119.3058473500937, 34.66387620237016],
        [119.30574254976909, 34.63041169680007],
        [119.23071540183122, 34.630255366340634],
        [119.23062143399773, 34.6640111299246],
    ]],
}


@dataclass
class DemPaths:
    work_dir: Path
    source_tif: Path
    clipped_tif: Path
    metadata_json: Path
    cutline_geojson: Path
    tile_dir: Path


@dataclass
class DemStats:
    width: int
    height: int
    min_elevation: float | None
    max_elevation: float | None
    mean_elevation: float | None
    bounds_projected: tuple[float, float, float, float]
    geo_transform: tuple[float, float, float, float, float, float]
    nodata: float


def run(command: Sequence[str]) -> None:
    print("+ " + " ".join(str(part) for part in command), file=sys.stderr)
    subprocess.run(command, check=True)


def ensure_gdal_tools() -> None:
    missing = [tool for tool in ("gdalwarp", "gdalinfo", "gdal_translate") if shutil.which(tool) is None]
    if missing:
        raise RuntimeError(f"Missing required GDAL tools: {', '.join(missing)}")


def download(url: str, path: Path, force: bool = False) -> None:
    if path.exists() and not force:
        print(f"Using existing DEM source: {path}", file=sys.stderr)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".download")
    print(f"Downloading {url} -> {path}", file=sys.stderr)
    with requests.get(url, stream=True, timeout=120) as response:
        response.raise_for_status()
        with temp.open("wb") as file:
            for chunk in response.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    file.write(chunk)
    temp.replace(path)


def load_area_geometry(area_geojson: Path | None) -> BaseGeometry:
    if area_geojson is None:
        return shape(AREA_GEOJSON)

    payload = json.loads(area_geojson.read_text(encoding="utf-8"))
    payload_type = payload.get("type")
    if payload_type == "FeatureCollection":
        geometries = [shape(feature["geometry"]) for feature in payload.get("features", []) if feature.get("geometry")]
        if not geometries:
            raise RuntimeError(f"Area GeoJSON has no geometries: {area_geojson}")
        area = unary_union(geometries)
    elif payload_type == "Feature":
        area = shape(payload["geometry"])
    else:
        area = shape(payload)

    if area.is_empty:
        raise RuntimeError(f"Area GeoJSON is empty: {area_geojson}")
    return area


def buffered_projected_area(area: BaseGeometry, buffer_m: float, target_srid: int) -> BaseGeometry:
    transformer = Transformer.from_crs("EPSG:4326", f"EPSG:{target_srid}", always_xy=True)
    projected = shapely_transform(transformer.transform, area)
    if projected.is_empty:
        raise RuntimeError("Projected area geometry is empty")
    return projected.buffer(buffer_m) if buffer_m else projected


def write_cutline_geojson(area_projected: BaseGeometry, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "type": "FeatureCollection",
        "features": [{
            "type": "Feature",
            "properties": {},
            "geometry": mapping(area_projected),
        }],
    }
    path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")


def prepare_dem(
    paths: DemPaths,
    area: BaseGeometry,
    source_url: str,
    source_file: Path | None,
    target_srid: int,
    resolution_m: float,
    buffer_m: float,
    force_download: bool,
    force_process: bool,
) -> DemStats:
    ensure_gdal_tools()
    if source_file is None:
        download(source_url, paths.source_tif, force_download)
        source_path = paths.source_tif
    else:
        source_path = source_file
        if not source_path.exists():
            raise FileNotFoundError(f"DEM source file not found: {source_path}")
        print(f"Using local DEM source: {source_path}", file=sys.stderr)

    buffered_area = buffered_projected_area(area, buffer_m, target_srid)
    minx, miny, maxx, maxy = buffered_area.bounds
    if force_process or not paths.clipped_tif.exists():
        paths.clipped_tif.parent.mkdir(parents=True, exist_ok=True)
        write_cutline_geojson(buffered_area, paths.cutline_geojson)
        run([
            "gdalwarp",
            "-overwrite",
            "-t_srs", f"EPSG:{target_srid}",
            "-te_srs", f"EPSG:{target_srid}",
            "-te", f"{minx:.3f}", f"{miny:.3f}", f"{maxx:.3f}", f"{maxy:.3f}",
            "-cutline", str(paths.cutline_geojson),
            "-cutline_srs", f"EPSG:{target_srid}",
            "-crop_to_cutline",
            "-tr", str(resolution_m), str(resolution_m),
            "-tap",
            "-r", "bilinear",
            "-dstnodata", "-9999",
            "-co", "TILED=YES",
            "-co", "COMPRESS=DEFLATE",
            str(source_path),
            str(paths.clipped_tif),
        ])
    else:
        print(f"Using existing clipped DEM: {paths.clipped_tif}", file=sys.stderr)

    return read_gdal_stats(paths.clipped_tif, paths.metadata_json)


def read_gdal_stats(tif: Path, metadata_json: Path | None = None) -> DemStats:
    if metadata_json is not None:
        metadata_json.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(["gdalinfo", "-json", "-stats", str(tif)], check=True, text=True, capture_output=True)
    if metadata_json is not None:
        metadata_json.write_text(result.stdout, encoding="utf-8")
    metadata = json.loads(result.stdout)
    band = metadata["bands"][0]
    nodata = parse_float(band.get("noDataValue"))
    stats = band.get("metadata", {}).get("", {})
    corner = metadata["cornerCoordinates"]
    upper_left = corner["upperLeft"]
    lower_right = corner["lowerRight"]
    return DemStats(
        width=int(metadata["size"][0]),
        height=int(metadata["size"][1]),
        min_elevation=parse_float(stats.get("STATISTICS_MINIMUM")),
        max_elevation=parse_float(stats.get("STATISTICS_MAXIMUM")),
        mean_elevation=parse_float(stats.get("STATISTICS_MEAN")),
        bounds_projected=(float(upper_left[0]), float(lower_right[1]), float(lower_right[0]), float(upper_left[1])),
        geo_transform=tuple(float(value) for value in metadata["geoTransform"]),
        nodata=-9999.0 if nodata is None else nodata,
    )


def parse_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def read_raster_values_xyz(tif: Path, width: int, height: int) -> list[list[float]]:
    """Read one DEM tile through GDAL XYZ output as a row-major 2D array."""
    result = subprocess.run(["gdal_translate", "-q", "-of", "XYZ", str(tif), "/vsistdout/"], check=True, text=True, capture_output=True)
    values: list[float] = []
    for line in result.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split()
        values.append(float(parts[-1]))
    expected = width * height
    if len(values) != expected:
        raise RuntimeError(f"GDAL XYZ returned {len(values)} values, expected {expected}")
    return [values[row * width:(row + 1) * width] for row in range(height)]


def create_terrain_schema(conn: psycopg.Connection[Any], target_srid: int) -> None:
    sql = f"""
    create extension if not exists postgis;
    create extension if not exists postgis_raster;
    create schema if not exists terrain;

    create table if not exists terrain.dem_dataset (
      id bigserial primary key,
      dataset_key text not null unique,
      source_name text not null,
      source_url text,
      license text,
      version text,
      horizontal_srid integer not null default {target_srid},
      vertical_datum text,
      resolution_m double precision,
      acquisition_info text,
      processing_info text,
      extent geometry(PolygonZ, {target_srid}),
      created_at timestamptz not null default now(),
      updated_at timestamptz not null default now()
    );

    create table if not exists terrain.dem_tile (
      id bigserial primary key,
      dataset_id bigint not null references terrain.dem_dataset(id) on delete cascade,
      tile_id text not null,
      rast raster not null,
      extent geometry(Polygon, {target_srid}) not null,
      min_elevation double precision,
      max_elevation double precision,
      mean_elevation double precision,
      created_at timestamptz not null default now(),
      updated_at timestamptz not null default now(),
      unique (dataset_id, tile_id)
    );

    create index if not exists dem_tile_extent_gix
      on terrain.dem_tile using gist (extent);

    create or replace function terrain.get_elevation(
      x double precision,
      y double precision,
      p_dataset_key text default null
    ) returns double precision
    language sql stable parallel safe as $$
      with p as (
        select ST_SetSRID(ST_MakePoint(x, y), {target_srid}) as geom
      ), candidates as (
        select ST_Value(t.rast, 1, p.geom, true) as z, d.created_at
        from p
        join terrain.dem_tile t on t.extent && p.geom and ST_Intersects(t.extent, p.geom)
        join terrain.dem_dataset d on d.id = t.dataset_id
        where p_dataset_key is null or d.dataset_key = p_dataset_key
      )
      select z
      from candidates
      where z is not null and z > -9000
      order by created_at desc
      limit 1
    $$;

    create or replace function terrain.get_elevation_for_geom(
      input_geom geometry,
      method text default 'median',
      p_dataset_key text default null
    ) returns double precision
    language plpgsql stable as $$
    declare
      geom_2d geometry;
      result double precision;
    begin
      if input_geom is null or ST_IsEmpty(input_geom) then
        return null;
      end if;

      geom_2d := ST_Force2D(input_geom);
      if ST_SRID(geom_2d) <> {target_srid} then
        geom_2d := ST_Transform(geom_2d, {target_srid});
      end if;

      if method = 'centroid' then
        return terrain.get_elevation(ST_X(ST_PointOnSurface(geom_2d)), ST_Y(ST_PointOnSurface(geom_2d)), p_dataset_key);
      end if;

      with candidate_points as (
        select ST_PointOnSurface(geom_2d) as geom
        union all
        select (dumped).geom
        from ST_DumpPoints(ST_Boundary(geom_2d)) as dumped
      ), sampled as (
        select terrain.get_elevation(ST_X(geom), ST_Y(geom), p_dataset_key) as z
        from candidate_points
      )
      select case
        when method = 'min' then min(z)
        when method = 'max' then max(z)
        else percentile_cont(0.5) within group (order by z)
      end
      into result
      from sampled
      where z is not null;

      if result is null then
        result := terrain.get_elevation(ST_X(ST_PointOnSurface(geom_2d)), ST_Y(ST_PointOnSurface(geom_2d)), p_dataset_key);
      end if;

      return result;
    end;
    $$;
    """
    with conn.cursor() as cur:
        cur.execute(sql)
    conn.commit()


def estimate_tile_count(stats: DemStats, tile_size: int) -> int:
    return ((stats.width + tile_size - 1) // tile_size) * ((stats.height + tile_size - 1) // tile_size)


def upsert_dem_dataset(
    conn: psycopg.Connection[Any],
    stats: DemStats,
    dataset_key: str,
    source_name: str,
    source_url: str,
    source_license: str,
    source_version: str,
    vertical_datum: str,
    resolution_m: float,
    processing_info: str,
    target_srid: int,
) -> int:
    target_srid = int(target_srid)
    minx, miny, maxx, maxy = stats.bounds_projected
    with conn.cursor() as cur:
        cur.execute(
            f"""
            insert into terrain.dem_dataset (
              dataset_key, source_name, source_url, license, version,
              horizontal_srid, vertical_datum, resolution_m, processing_info,
              extent, updated_at
            ) values (
              %s, %s, %s, %s, %s,
              %s, %s, %s, %s,
              ST_Force3DZ(ST_MakeEnvelope(%s, %s, %s, %s, {target_srid}), coalesce(%s, 0))::geometry(PolygonZ, {target_srid}),
              now()
            )
            on conflict (dataset_key) do update set
              source_name = excluded.source_name,
              source_url = excluded.source_url,
              license = excluded.license,
              version = excluded.version,
              horizontal_srid = excluded.horizontal_srid,
              vertical_datum = excluded.vertical_datum,
              resolution_m = excluded.resolution_m,
              processing_info = excluded.processing_info,
              extent = excluded.extent,
              updated_at = now()
            returning id
            """,
            (
                dataset_key,
                source_name,
                source_url,
                source_license,
                source_version,
                target_srid,
                vertical_datum,
                resolution_m,
                processing_info,
                minx,
                miny,
                maxx,
                maxy,
                stats.min_elevation,
            ),
        )
        dataset_id = int(cur.fetchone()[0])
        cur.execute("delete from terrain.dem_tile where dataset_id = %s", (dataset_id,))
    return dataset_id


def make_tile_file(source_tif: Path, tile_tif: Path, xoff: int, yoff: int, width: int, height: int, force: bool) -> None:
    if tile_tif.exists() and not force:
        return
    tile_tif.parent.mkdir(parents=True, exist_ok=True)
    run([
        "gdal_translate",
        "-q",
        "-srcwin", str(xoff), str(yoff), str(width), str(height),
        "-of", "GTiff",
        "-co", "TILED=YES",
        "-co", "COMPRESS=DEFLATE",
        str(source_tif),
        str(tile_tif),
    ])


def insert_dem_tile(
    cur: psycopg.Cursor[Any],
    tile_tif: Path,
    tile_stats: DemStats,
    dataset_id: int,
    tile_id: str,
    target_srid: int,
) -> None:
    target_srid = int(target_srid)
    values = read_raster_values_xyz(tile_tif, tile_stats.width, tile_stats.height)
    origin_x, scale_x, skew_x, origin_y, skew_y, scale_y = tile_stats.geo_transform
    cur.execute(
        f"""
        with src as (
          select ST_SetValues(
            ST_AddBand(
              ST_MakeEmptyRaster(%s, %s, %s, %s, %s, %s, %s, %s, {target_srid}),
              '32BF'::text,
              %s,
              %s
            ),
            1,
            1,
            1,
            %s::double precision[][]
          ) as rast
        ), stats as (
          select (ST_SummaryStats(rast, 1, true)).* from src
        )
        insert into terrain.dem_tile (
          dataset_id, tile_id, rast, extent,
          min_elevation, max_elevation, mean_elevation, updated_at
        )
        select
          %s, %s, src.rast,
          ST_ConvexHull(src.rast)::geometry(Polygon, {target_srid}),
          stats.min, stats.max, stats.mean, now()
        from src, stats
        on conflict (dataset_id, tile_id) do update set
          rast = excluded.rast,
          extent = excluded.extent,
          min_elevation = excluded.min_elevation,
          max_elevation = excluded.max_elevation,
          mean_elevation = excluded.mean_elevation,
          updated_at = now()
        """,
        (
            tile_stats.width,
            tile_stats.height,
            origin_x,
            origin_y,
            scale_x,
            scale_y,
            skew_x,
            skew_y,
            tile_stats.nodata,
            tile_stats.nodata,
            values,
            dataset_id,
            tile_id,
        ),
    )


def import_tiled_raster(
    conn: psycopg.Connection[Any],
    tif: Path,
    stats: DemStats,
    dataset_key: str,
    tile_id_prefix: str,
    source_name: str,
    source_url: str,
    source_license: str,
    source_version: str,
    vertical_datum: str,
    resolution_m: float,
    processing_info: str,
    target_srid: int,
    tile_size: int,
    tile_dir: Path,
    force_process: bool,
) -> dict[str, int]:
    if tile_size <= 0:
        raise ValueError("tile_size must be positive")
    if force_process and tile_dir.exists():
        shutil.rmtree(tile_dir)

    dataset_id = upsert_dem_dataset(
        conn,
        stats,
        dataset_key,
        source_name,
        source_url,
        source_license,
        source_version,
        vertical_datum,
        resolution_m,
        processing_info,
        target_srid,
    )

    imported_tiles = 0
    skipped_nodata_tiles = 0
    with conn.cursor() as cur:
        for yoff in range(0, stats.height, tile_size):
            for xoff in range(0, stats.width, tile_size):
                width = min(tile_size, stats.width - xoff)
                height = min(tile_size, stats.height - yoff)
                row = yoff // tile_size
                col = xoff // tile_size
                tile_id = f"{tile_id_prefix}-r{row:04d}-c{col:04d}"
                tile_tif = tile_dir / f"{tile_id}.tif"
                make_tile_file(tif, tile_tif, xoff, yoff, width, height, force_process)
                tile_stats = read_gdal_stats(tile_tif)
                if tile_stats.min_elevation is None or tile_stats.max_elevation is None:
                    skipped_nodata_tiles += 1
                    continue
                insert_dem_tile(cur, tile_tif, tile_stats, dataset_id, tile_id, target_srid)
                imported_tiles += 1

    conn.commit()
    return {
        "dataset_id": dataset_id,
        "imported_tile_count": imported_tiles,
        "skipped_nodata_tile_count": skipped_nodata_tiles,
    }


def cleanup_citydb_feature(cur: psycopg.Cursor[Any], feature_id: int) -> None:
    cur.execute("delete from citydb.property where feature_id = %s", (feature_id,))
    cur.execute("delete from citydb.geometry_data where feature_id = %s", (feature_id,))


def upsert_feature(cur: psycopg.Cursor[Any], objectid: str, objectclass_id: int, identifier: str, lineage: str, envelope_wkt: str, target_srid: int) -> int:
    cur.execute("select id from citydb.feature where objectid = %s", (objectid,))
    row = cur.fetchone()
    if row:
        feature_id = int(row[0])
        cleanup_citydb_feature(cur, feature_id)
        cur.execute(
            """
            update citydb.feature
            set objectclass_id = %s,
                identifier = %s,
                identifier_codespace = 'terrain',
                envelope = ST_GeomFromText(%s::text, %s),
                last_modification_date = now(),
                updating_person = current_user,
                reason_for_update = 'DEM terrain import refresh',
                lineage = %s
            where id = %s
            """,
            (objectclass_id, identifier, envelope_wkt, target_srid, lineage, feature_id),
        )
    else:
        cur.execute(
            """
            insert into citydb.feature
              (objectclass_id, objectid, identifier, identifier_codespace, envelope, creation_date, lineage)
            values (%s, %s, %s, 'terrain', ST_GeomFromText(%s::text, %s), now(), %s)
            returning id
            """,
            (objectclass_id, objectid, identifier, envelope_wkt, target_srid, lineage),
        )
        feature_id = int(cur.fetchone()[0])
    return feature_id


def insert_string_property(cur: psycopg.Cursor[Any], feature_id: int, name: str, value: str, namespace_id: int = 3) -> None:
    if isinstance(value, memoryview):
        value = bytes(value).decode("utf-8", errors="replace")
    elif isinstance(value, (bytes, bytearray)):
        value = bytes(value).decode("utf-8", errors="replace")
    else:
        value = str(value)
    cur.execute(
        """
        insert into citydb.property (feature_id, datatype_id, namespace_id, name, val_string)
        values (%s, 5, %s, %s, %s)
        """,
        (feature_id, namespace_id, name, value[:4000]),
    )


def insert_double_property(cur: psycopg.Cursor[Any], feature_id: int, name: str, value: float, namespace_id: int = 3, uom: str = "m") -> None:
    cur.execute(
        """
        insert into citydb.property (feature_id, datatype_id, namespace_id, name, val_double, val_uom)
        values (%s, 4, %s, %s, %s, %s)
        """,
        (feature_id, namespace_id, name, value, uom),
    )


def upsert_citydb_relief(conn: psycopg.Connection[Any], dataset_key: str, project_key: str, target_srid: int) -> dict[str, int]:
    relief_objectid = f"terrain:relief:{project_key}:{dataset_key}"
    raster_objectid = f"terrain:raster-relief:{project_key}:{dataset_key}"
    lineage = "Open DEM terrain import; raster values stored in terrain.dem_tile and referenced from RasterRelief metadata"

    with conn.cursor() as cur:
        cur.execute("select id, source_name, source_url, license, version, vertical_datum, resolution_m from terrain.dem_dataset where dataset_key = %s", (dataset_key,))
        ds = cur.fetchone()
        if ds is None:
            raise RuntimeError(f"DEM dataset not found: {dataset_key}")
        dataset_id, source_name, source_url, license_text, version, vertical_datum, resolution_m = ds
        cur.execute(
            """
            select ST_AsText(ST_Force3DZ(ST_Force2D(extent), coalesce((select min(min_elevation) from terrain.dem_tile where dataset_id = ds.id), 0)))
            from terrain.dem_dataset ds
            where ds.dataset_key = %s
            """,
            (dataset_key,),
        )
        envelope_wkt_value = cur.fetchone()[0]
        if isinstance(envelope_wkt_value, (bytes, bytearray, memoryview)):
            envelope_wkt = bytes(envelope_wkt_value).decode("utf-8")
        else:
            envelope_wkt = str(envelope_wkt_value)

        raster_feature_id = upsert_feature(
            cur,
            raster_objectid,
            505,
            raster_objectid,
            lineage,
            envelope_wkt,
            target_srid,
        )

        cur.execute(
            """
            insert into citydb.geometry_data (geometry, geometry_properties, feature_id)
            select ST_Force3DZ(ST_Force2D(extent), coalesce((select min(min_elevation) from terrain.dem_tile where dataset_id = ds.id), 0)),
                   '{"type": 5}'::jsonb,
                   %s
            from terrain.dem_dataset ds
            where ds.dataset_key = %s
            returning id
            """,
            (raster_feature_id, dataset_key),
        )
        extent_geometry_id = int(cur.fetchone()[0])
        cur.execute(
            """
            insert into citydb.property (feature_id, datatype_id, namespace_id, name, val_lod, val_geometry_id)
            values (%s, 11, 6, 'extent', '1', %s)
            """,
            (raster_feature_id, extent_geometry_id),
        )
        cur.execute(
            "insert into citydb.property (feature_id, datatype_id, namespace_id, name, val_int) values (%s, 3, 6, 'lod', 1)",
            (raster_feature_id,),
        )

        metadata = {
            "demSource": source_name,
            "demDatasetKey": dataset_key,
            "demDatasetId": str(dataset_id),
            "demTable": "terrain.dem_tile",
            "demSourceUrl": source_url or "",
            "demLicense": license_text or "",
            "demVersion": version or "",
            "verticalDatum": vertical_datum or "",
            "processingPurpose": "Approximate terrain elevation for building base-z and coarse UAV planning",
        }
        for name, value in metadata.items():
            insert_string_property(cur, raster_feature_id, name, value)
        if resolution_m is not None:
            insert_double_property(cur, raster_feature_id, "demResolution", float(resolution_m))

        relief_feature_id = upsert_feature(
            cur,
            relief_objectid,
            500,
            relief_objectid,
            lineage,
            envelope_wkt,
            target_srid,
        )
        cur.execute(
            "insert into citydb.property (feature_id, datatype_id, namespace_id, name, val_int) values (%s, 3, 6, 'lod', 1)",
            (relief_feature_id,),
        )
        cur.execute(
            """
            insert into citydb.property
              (feature_id, datatype_id, namespace_id, name, val_feature_id, val_relation_type)
            values (%s, 10, 6, 'reliefComponent', %s, 1)
            """,
            (relief_feature_id, raster_feature_id),
        )
    conn.commit()
    return {"relief_feature_id": relief_feature_id, "raster_relief_feature_id": raster_feature_id}


def validate(conn: psycopg.Connection[Any], dataset_key: str, area: BaseGeometry, project_key: str, target_srid: int) -> dict[str, Any]:
    transformer = Transformer.from_crs("EPSG:4326", f"EPSG:{target_srid}", always_xy=True)
    centroid = shapely_transform(transformer.transform, area).centroid
    with conn.cursor() as cur:
        cur.execute(
            """
            select ds.id, ds.dataset_key, count(t.*), min(t.min_elevation), max(t.max_elevation), avg(t.mean_elevation)
            from terrain.dem_dataset ds
            left join terrain.dem_tile t on t.dataset_id = ds.id
            where ds.dataset_key = %s
            group by ds.id, ds.dataset_key
            """,
            (dataset_key,),
        )
        ds_row = cur.fetchone()
        cur.execute("select terrain.get_elevation(%s, %s, %s)", (centroid.x, centroid.y, dataset_key))
        sample_elevation = cur.fetchone()[0]
        cur.execute(
            """
            select objectclass_id, count(*)
            from citydb.feature
            where objectid in (%s, %s)
            group by objectclass_id
            order by objectclass_id
            """,
            (f"terrain:relief:{project_key}:{dataset_key}", f"terrain:raster-relief:{project_key}:{dataset_key}"),
        )
        relief_counts = {str(row[0]): row[1] for row in cur.fetchall()}
    return {
        "dataset": None if ds_row is None else {
            "id": ds_row[0],
            "dataset_key": ds_row[1],
            "tile_count": ds_row[2],
            "min_elevation": ds_row[3],
            "max_elevation": ds_row[4],
            "mean_elevation": ds_row[5],
        },
        "sample_project_centroid_elevation_m": sample_elevation,
        "citydb_relief_feature_counts_by_objectclass": relief_counts,
    }


def json_default(value: Any) -> Any:
    if isinstance(value, memoryview):
        return bytes(value).decode("utf-8", errors="replace")
    if isinstance(value, (bytes, bytearray)):
        return bytes(value).decode("utf-8", errors="replace")
    raise TypeError(f"Object of type {value.__class__.__name__} is not JSON serializable")


def main(argv: Sequence[str] | None = None) -> int:
    raw_argv = list(sys.argv[1:] if argv is None else argv)
    source_url_arg_set = any(arg == "--source-url" or arg.startswith("--source-url=") for arg in raw_argv)
    source_version_arg_set = any(arg == "--source-version" or arg.startswith("--source-version=") for arg in raw_argv)

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dsn", default=os.getenv("DATABASE_URL", DEFAULT_DSN))
    parser.add_argument("--dataset-key", default=DATASET_KEY)
    parser.add_argument("--project-key", default=PROJECT_KEY)
    parser.add_argument("--area-geojson", help="EPSG:4326 GeoJSON geometry/feature/feature collection defining the import area.")
    parser.add_argument("--source-url", default=SOURCE_URL, help="DEM GeoTIFF URL used when --source-file is not provided.")
    parser.add_argument("--source-file", help="Local DEM source GeoTIFF/VRT mosaic. Skips downloading --source-url.")
    parser.add_argument("--source-name", default=SOURCE_NAME)
    parser.add_argument("--source-license", default=SOURCE_LICENSE)
    parser.add_argument("--source-version", default=SOURCE_VERSION)
    parser.add_argument("--vertical-datum", default=VERTICAL_DATUM)
    parser.add_argument("--target-srid", type=int, default=TARGET_SRID)
    parser.add_argument("--resolution-m", type=float, default=RESOLUTION_M)
    parser.add_argument("--buffer-m", type=float, default=1000.0)
    parser.add_argument("--work-dir", default="data/dem")
    parser.add_argument("--tile-id", default="huaguoshan-dem-32650", help="Prefix for generated terrain.dem_tile.tile_id values.")
    parser.add_argument("--tile-size", type=int, default=256, help="Raster tile width/height in pixels for database import.")
    parser.add_argument("--force-download", action="store_true")
    parser.add_argument("--force-process", action="store_true")
    parser.add_argument("--execute", action="store_true", help="Write to database. Without this flag, only downloads/processes DEM.")
    args = parser.parse_args(raw_argv)

    if args.tile_size <= 0:
        parser.error("--tile-size must be positive")

    area_geojson = Path(args.area_geojson) if args.area_geojson else None
    source_file = Path(args.source_file) if args.source_file else None
    area = load_area_geometry(area_geojson)
    source_url = args.source_url
    source_version = args.source_version
    if source_file is not None:
        if not source_url_arg_set:
            source_url = str(source_file)
        if not source_version_arg_set:
            source_version = f"Local GDAL source file/VRT: {source_file.name}"

    work_dir = Path(args.work_dir)
    source_tif_name = args.source_url.rsplit("/", 1)[-1] or "source_dem.tif"
    paths = DemPaths(
        work_dir=work_dir,
        source_tif=work_dir / "source" / source_tif_name,
        clipped_tif=work_dir / f"{args.dataset_key}_epsg{args.target_srid}.tif",
        metadata_json=work_dir / f"{args.dataset_key}_epsg{args.target_srid}_gdalinfo.json",
        cutline_geojson=work_dir / f"{args.dataset_key}_epsg{args.target_srid}_cutline.geojson",
        tile_dir=work_dir / "tiles" / args.dataset_key,
    )

    stats = prepare_dem(
        paths,
        area,
        args.source_url,
        source_file,
        args.target_srid,
        args.resolution_m,
        args.buffer_m,
        args.force_download,
        args.force_process,
    )
    tile_count_estimate = estimate_tile_count(stats, args.tile_size)
    report: dict[str, Any] = {
        "dataset_key": args.dataset_key,
        "project_key": args.project_key,
        "area_geojson": str(area_geojson) if area_geojson else "built-in-huaguoshan-area",
        "source_name": args.source_name,
        "source_url": source_url,
        "source_file": str(source_file) if source_file else None,
        "source_version": source_version,
        "clipped_tif": str(paths.clipped_tif),
        "tile_dir": str(paths.tile_dir),
        "tile_size": args.tile_size,
        "estimated_tile_count": tile_count_estimate,
        "width": stats.width,
        "height": stats.height,
        "bounds_projected": stats.bounds_projected,
        "gdal_stats": {
            "min_elevation": stats.min_elevation,
            "max_elevation": stats.max_elevation,
            "mean_elevation": stats.mean_elevation,
        },
        "note": "DEM is approximate open elevation data, not LiDAR/photogrammetry/authoritative 3D city model data.",
    }

    if args.execute:
        source_action = f"Used local DEM source {source_file}" if source_file is not None else f"Downloaded source COG from {args.source_url}"
        area_label = str(area_geojson) if area_geojson else "built-in Huaguoshan area"
        processing_info = (
            f"{source_action}; clipped to {area_label} with {args.buffer_m:g} m projected buffer using a GDAL cutline; "
            f"reprojected to EPSG:{args.target_srid}, resolution {args.resolution_m:g} m; "
            f"imported as {args.tile_size}x{args.tile_size} pixel PostGIS raster tiles."
        )
        with psycopg.connect(args.dsn, connect_timeout=15) as conn:
            create_terrain_schema(conn, args.target_srid)
            import_result = import_tiled_raster(
                conn,
                paths.clipped_tif,
                stats,
                args.dataset_key,
                args.tile_id,
                args.source_name,
                source_url,
                args.source_license,
                source_version,
                args.vertical_datum,
                args.resolution_m,
                processing_info,
                args.target_srid,
                args.tile_size,
                paths.tile_dir,
                args.force_process,
            )
            relief_ids = upsert_citydb_relief(conn, args.dataset_key, args.project_key, args.target_srid)
            report["database"] = {
                **import_result,
                **relief_ids,
                "validation": validate(conn, args.dataset_key, area, args.project_key, args.target_srid),
            }
    else:
        report["database"] = None
        print("Dry run only. Re-run with --execute to import DEM into database.", file=sys.stderr)

    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True, default=json_default))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
