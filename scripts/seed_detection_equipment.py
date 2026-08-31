#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "psycopg[binary]>=3.2",
# ]
# ///
"""Seed simulated detection/response equipment into the existing equipment model.

The script requires the Phase 1 migration to have been applied first. Each of
seven equipment types receives a random number of assets between 5 and 10.
Asset points are generated inside the supplied business polygon; PostGIS clips
capability coverage to that same polygon. The default seed is deterministic so
an operator can reproduce a demo dataset.
"""

from __future__ import annotations

import argparse
import os
import random
import sys
from dataclasses import dataclass
from typing import Any

import psycopg
from psycopg.types.json import Jsonb


DEFAULT_DSN = "postgresql://postgres:postgres@10.1.109.151:5432/huaguoshan_projd"
SOURCE_SYSTEM = "seed_detection_equipment"
AREA_WKT = (
    "POLYGON((119.291647 34.7762417, 119.2806466 34.7503958, "
    "119.2797665 34.7301472, 119.2931871 34.7151383, "
    "119.315848 34.6921677, 119.3499494 34.6784185, "
    "119.3756904 34.6805895, 119.389331 34.6977753, "
    "119.3998914 34.7205635, 119.4027516 34.7328594, "
    "119.4045116 34.7467803, 119.3719503 34.7500343, "
    "119.3662301 34.7626872, 119.3512694 34.7644946, "
    "119.3336687 34.7596145, 119.316728 34.7661212, "
    "119.291647 34.7762417))"
)
AREA_VERTICES = [
    (119.291647, 34.7762417), (119.2806466, 34.7503958),
    (119.2797665, 34.7301472), (119.2931871, 34.7151383),
    (119.315848, 34.6921677), (119.3499494, 34.6784185),
    (119.3756904, 34.6805895), (119.389331, 34.6977753),
    (119.3998914, 34.7205635), (119.4027516, 34.7328594),
    (119.4045116, 34.7467803), (119.3719503, 34.7500343),
    (119.3662301, 34.7626872), (119.3512694, 34.7644946),
    (119.3336687, 34.7596145), (119.316728, 34.7661212),
]


@dataclass(frozen=True)
class EquipmentType:
    category: str
    prefix: str
    type_code: str
    label: str
    capabilities: tuple[tuple[str, str, dict[str, Any]], ...]


EQUIPMENT_TYPES = (
    EquipmentType("base_station_6g", "6G", "integrated_sensing", "6G 通感一体化基站", (("network_sensing_6g", "observable", {"radius_m": 1800}),)),
    EquipmentType("jamming_device", "JAM", "directional_radio_jammer", "定向无线电干扰设备", (("radio_jamming", "recommendable", {"radius_m": 1800, "simulated": True}),)),
    EquipmentType("aoa_direction_finder", "AOA", "wideband_direction_finder", "无线电到达角测向设备", (("aoa_measurement", "recommendable", {"azimuth_accuracy_deg": 3}),)),
    EquipmentType("microwave_radar", "MWR", "low_altitude_microwave_radar", "低空微波探测设备", (("microwave_detection", "recommendable", {"radius_m": 3000}), ("range_measurement", "recommendable", {}), ("velocity_measurement", "recommendable", {}))),
    EquipmentType("remote_id_receiver", "RID", "remote_id_fixed_receiver", "RemoteID 接收设备", (("remote_id_identification", "observable", {"radius_m": 2500}),)),
    EquipmentType("directed_energy_device", "LASER", "simulated_laser_response", "激光定向能处置设备", (("directed_energy_response", "recommendable", {"radius_m": 1200, "simulated_linkage_only": True}),)),
    EquipmentType("electro_optical_device", "EO", "thermal_ptz", "光电观测设备", (("electro_optical_observation", "linkable", {"radius_m": 2200}), ("electro_optical_tracking", "linkable", {}))),
)

PROFILE_DATA: dict[str, dict[str, Any]] = {
    "base_station_6g": {"table": "base_station_6g_profile", "columns": ("operator_name", "frequency_band", "bandwidth_mhz", "backhaul_type"), "values": ("低空应急技术保障组", "simulated-mmWave-sub-THz", 400, "fiber")},
    "jamming_device": {"table": "jamming_device_profile", "columns": ("jamming_modes", "frequency_range", "max_effective_range_m", "directional_supported", "target_protocols", "recommendation_notes"), "values": (["directional_simulation"], "simulated-licensed-bands", 1800, True, ["simulated_radio_link"], "仅用于能力展示和处置方案推荐，不提供直接控制。")},
    "aoa_direction_finder": {"table": "aoa_direction_finder_profile", "columns": ("frequency_range", "azimuth_min_deg", "azimuth_max_deg", "azimuth_accuracy_deg", "elevation_supported", "localization_mode", "antenna_count", "recommendation_notes"), "values": ("simulated-wideband", 0, 360, 3.0, False, "single_station_bearing", 4, "模拟到达角观测，可与其他来源进行目标融合。")},
    "microwave_radar": {"table": "microwave_radar_profile", "columns": ("frequency_band", "detection_mode", "max_detection_range_m", "min_detection_range_m", "min_target_speed_mps", "max_target_speed_mps", "range_accuracy_m", "speed_accuracy_mps", "multi_target_supported", "recommendation_notes"), "values": ("simulated-microwave", "low_altitude_3d_detection", 3000, 30, 0.5, 65, 8, 0.8, True, "模拟目标探测、测距和测速数据源。")},
    "remote_id_receiver": {"table": "remote_id_receiver_profile", "columns": ("protocol_codes", "receive_mode", "max_receive_range_m", "identity_resolution_mode", "time_synchronization_source", "recommendation_notes"), "values": (["simulated_remote_id"], "fixed_continuous_receive", 2500, "broadcast_identity_match", "platform_simulated_clock", "模拟 RemoteID 身份观测，不将广播标识直接作为平台目标主键。")},
    "directed_energy_device": {"table": "directed_energy_device_profile", "columns": ("effect_type", "effective_range_m", "azimuth_coverage_deg", "elevation_coverage_deg", "tracking_supported", "authorization_required", "simulated_linkage_only", "recommendation_notes"), "values": ("simulated_directed_energy_response", 1200, 90, 35, True, True, True, "仅用于处置能力展示、人工确认和模拟联动。")},
    "electro_optical_device": {"table": "electro_optical_device_profile", "columns": ("optical_modes", "camera_type", "thermal_supported", "ptz_supported", "optical_zoom", "detection_range_m", "recognition_range_m", "identification_range_m", "tracking_supported", "stream_ref", "recommendation_notes"), "values": (["visible_light", "thermal_infrared"], "thermal_ptz", True, True, 30, 2200, 1200, 600, True, None, "模拟可见光和热成像复核能力，视频流仅保存安全引用。")},
}


def point_in_polygon(point: tuple[float, float]) -> bool:
    x, y = point
    inside = False
    for index, (x1, y1) in enumerate(AREA_VERTICES):
        x2, y2 = AREA_VERTICES[(index + 1) % len(AREA_VERTICES)]
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
            inside = not inside
    return inside


def random_point(rng: random.Random) -> tuple[float, float]:
    for _ in range(10_000):
        point = (rng.uniform(119.2797665, 119.4045116), rng.uniform(34.6784185, 34.7762417))
        if point_in_polygon(point):
            return point
    raise RuntimeError("could not generate a point inside the requested polygon")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument("--dsn", default=os.getenv("CITYDB_DSN", DEFAULT_DSN), help="PostgreSQL DSN; can also use CITYDB_DSN.")
    parser.add_argument("--seed", type=int, default=731, help="Random seed. Use a different value for another reproducible dataset.")
    return parser.parse_args()


def upsert_profile(cur: psycopg.Cursor[Any], category: EquipmentType, asset_id: int, index: int) -> None:
    data = PROFILE_DATA[category.category]
    values = list(data["values"])
    if category.category == "electro_optical_device":
        values[9] = f"vault://streams/simulated-hgs-north-eo-{asset_id}"
    columns = ("asset_id",) + data["columns"]
    placeholders = ("%s," * len(columns)).rstrip(",")
    assignments = ", ".join(f"{column} = excluded.{column}" for column in data["columns"])
    cur.execute(
        f"insert into equipment.{data['table']} ({', '.join(columns)}) values ({placeholders}) "
        f"on conflict (asset_id) do update set {assignments}",
        (asset_id, *values),
    )


def main() -> int:
    args = parse_args()
    rng = random.Random(args.seed)
    generated: list[tuple[EquipmentType, int, tuple[float, float], float]] = []
    for category in EQUIPMENT_TYPES:
        count = rng.randint(5, 10)
        for index in range(1, count + 1):
            generated.append((category, index, random_point(rng), round(rng.uniform(45, 225), 2)))

    try:
        with psycopg.connect(args.dsn, connect_timeout=15, client_encoding="UTF8") as conn, conn.cursor() as cur:
            asset_ids: dict[tuple[str, int], int] = {}
            for category, index, (longitude, latitude), elevation in generated:
                source_id = f"{category.prefix}-NORTH-{index:03d}"
                asset_code = f"HGS-{source_id}"
                cur.execute(
                    """insert into equipment.asset
                      (asset_code, category_code, type_code, name, source_system, source_asset_id,
                       managing_unit_name, deployment_mode, lifecycle_status, geom, elevation_amsl_m,
                       height_datum, manufacturer, model, serial_no, is_simulated, metadata)
                    values (%s, %s, %s, %s, %s, %s, '低空应急技术保障组', 'fixed', 'active',
                            ST_SetSRID(ST_MakePoint(%s, %s), 4326), %s, 'AMSL', '模拟厂商', %s, %s, true, %s)
                    on conflict (source_system, source_asset_id) do update set
                      asset_code = excluded.asset_code, category_code = excluded.category_code,
                      type_code = excluded.type_code, name = excluded.name, geom = excluded.geom,
                      elevation_amsl_m = excluded.elevation_amsl_m, model = excluded.model,
                      serial_no = excluded.serial_no, metadata = excluded.metadata
                    returning id""",
                    (asset_code, category.category, category.type_code, f"北侧区域{category.label} {index:02d}", SOURCE_SYSTEM, source_id, longitude, latitude, elevation, f"{category.prefix}-SIM-X1", f"SIM-{source_id}", Jsonb({"scenario": "detection_area", "simulated": True, "coverage_clipped_to_area": True})),
                )
                asset_id = int(cur.fetchone()[0])
                asset_ids[(category.category, index)] = asset_id
                upsert_profile(cur, category, asset_id, index)

            for category, index, _, _ in generated:
                asset_id = asset_ids[(category.category, index)]
                cur.execute(
                    """insert into equipment.asset_status_current
                      (asset_id, connectivity_status, dispatch_status, position_geom, position_height_amsl_m, height_datum, last_heartbeat_at, observed_at, payload)
                    select id, 'online', case when category_code in ('jamming_device', 'directed_energy_device') then 'unavailable' else 'unknown' end,
                           geom, elevation_amsl_m, 'AMSL', now(), now(), %s
                    from equipment.asset where id = %s
                    on conflict (asset_id) do update set connectivity_status = excluded.connectivity_status,
                      dispatch_status = excluded.dispatch_status, position_geom = excluded.position_geom,
                      position_height_amsl_m = excluded.position_height_amsl_m, observed_at = excluded.observed_at,
                      payload = excluded.payload""",
                    (Jsonb({"source": SOURCE_SYSTEM, "simulated": True}), asset_id),
                )
                for capability, access_level, parameters in category.capabilities:
                    cur.execute(
                        """insert into equipment.asset_capability(asset_id, capability_code, access_level, enabled, parameters)
                        values (%s, %s, %s, true, %s)
                        on conflict (asset_id, capability_code) do update set access_level = excluded.access_level,
                          enabled = excluded.enabled, parameters = excluded.parameters
                        returning id""",
                        (asset_id, capability, access_level, Jsonb(parameters)),
                    )
                    capability_id = int(cur.fetchone()[0])
                    radius = int(parameters.get("radius_m", 2200))
                    cur.execute(
                        """insert into equipment.asset_coverage
                          (asset_capability_id, coverage_geom, min_height_amsl_m, max_height_amsl_m, height_datum, metadata)
                        select %s, ST_Multi(ST_Intersection(ST_Buffer(a.geom::geography, %s)::geometry, ST_GeomFromText(%s, 4326))),
                          a.elevation_amsl_m, a.elevation_amsl_m + case when %s = 'directed_energy_response' then 300 else 500 end,
                          'AMSL', %s
                        from equipment.asset a
                        where a.id = %s and not exists (
                          select 1 from equipment.asset_coverage old where old.asset_capability_id = %s
                            and old.metadata @> '{"area_source":"user_feature_collection"}'::jsonb
                        )""",
                        (capability_id, radius, AREA_WKT, capability, Jsonb({"simulated": True, "coverage_model": "clipped_circle", "area_source": "user_feature_collection"}), asset_id, capability_id),
                    )
                observation_type = {"base_station_6g": "network_sensing_6g", "jamming_device": "jamming_status", "aoa_direction_finder": "aoa_bearing", "microwave_radar": "microwave_detection", "remote_id_receiver": "remote_id_broadcast", "directed_energy_device": "directed_energy_status", "electro_optical_device": "electro_optical_detection"}[category.category]
                source_id = f"{category.prefix}-NORTH-{index:03d}"
                cur.execute(
                    """insert into equipment.raw_observation
                      (asset_id, source_system, source_observation_id, observation_type, observed_at, received_at, geom, height_amsl_m, height_datum, confidence, processing_status, raw_payload, is_simulated)
                    select id, %s, %s, %s, now(), now(), geom, elevation_amsl_m, 'AMSL', 0.92, 'received', %s, true
                    from equipment.asset where id = %s
                    on conflict (source_system, source_observation_id) do nothing""",
                    (SOURCE_SYSTEM, f"{source_id}-OBS-001", observation_type, Jsonb({"source_asset_id": source_id, "simulated": True, "area_source": "user_feature_collection"}), asset_id),
                )
            conn.commit()

        counts: dict[str, int] = {}
        for category, _, _, _ in generated:
            counts[category.category] = counts.get(category.category, 0) + 1
        print(f"Seeded {len(generated)} simulated equipment assets with seed={args.seed}.")
        for category, count in counts.items():
            print(f"- {category}: {count}")
        return 0
    except (psycopg.Error, OSError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
