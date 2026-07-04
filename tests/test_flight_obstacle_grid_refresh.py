from __future__ import annotations

import argparse
import importlib.util
import sys
from pathlib import Path
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "refresh_citydb_obstacle_grids.py"
spec = importlib.util.spec_from_file_location("refresh_citydb_obstacle_grids", MODULE_PATH)
refresh = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = refresh
assert spec.loader is not None
spec.loader.exec_module(refresh)


def default_args(**overrides):
    values = dict(
        citydb_schema="citydb",
        grid_schema="citydb_grid",
        airspace_schema="airspace",
        total_view_name="flight_obstacles",
        codes_view_name="flight_obstacles_codes_view",
        public_wrapper_schema="public",
        public_wrapper_name="flight_obstacles",
        detail_level=19,
        auto_detail_level=False,
        is_agg=True,
        objectid_like=None,
        objectclass_id=[],
        limit=None,
        terrain_dataset_key=None,
        terrain_clearance_m=30.0,
        underground_tolerance_m=0.0,
        terrain_min_max_elevation_m=None,
        default_zone_max_height=500.0,
        planning_time=None,
        airspace_mode="bbox",
        terrain_mode="tile-bbox",
        terrain_block_size_pixels=4,
        terrain_lod_display=False,
        terrain_lod_view_name="obstacles_terrain_lod",
        terrain_lod_spec="0:32:15,1:16:17,2:4:19",
        refresh_only=False,
        dry_run=False,
        refresh_total=False,
        concurrently=True,
        sample_size=5,
        grant_role=None,
        skip_pgrst_notify=False,
        source="all",
    )
    values.update(overrides)
    return argparse.Namespace(**values)


def sql_text(statement) -> str:
    return " ".join(statement.as_string().split())


class FlightObstacleGridRefreshAdapterTests(unittest.TestCase):
    def test_source_adapters_cover_existing_source_views(self):
        args = default_args()

        adapters = refresh.obstacle_source_adapters(args, has_terrain_tables=True)

        self.assertEqual([adapter.source for adapter in adapters], list(refresh.SOURCE_ORDER))
        self.assertEqual([adapter.view_name for adapter in adapters], [refresh.SOURCE_TO_VIEW[source] for source in refresh.SOURCE_ORDER])
        for adapter in adapters:
            text = sql_text(adapter.build_view_sql())
            self.assertIn(f'create materialized view "citydb_grid"."{adapter.view_name}"', text)
            self.assertIn("source_kind", text)
            self.assertIn("grids", text)
            self.assertIn("priority", text)

    def test_airspace_constraint_adapters_share_one_configurable_implementation(self):
        args = default_args(planning_time="2026-07-04T12:00:00Z")

        adapters = {adapter.source: adapter for adapter in refresh.obstacle_source_adapters(args, has_terrain_tables=True)}
        no_fly = adapters["no-fly-zones"]
        temp_control = adapters["temp-control"]

        self.assertIs(type(no_fly), type(temp_control))
        no_fly_sql = sql_text(no_fly.build_view_sql())
        temp_sql = sql_text(temp_control.build_view_sql())
        self.assertIn('from "airspace"."no_fly_zone"', no_fly_sql)
        self.assertIn('from "airspace"."temp_control_zone"', temp_sql)
        self.assertIn("1000::integer as priority", no_fly_sql)
        self.assertIn("1100::integer as priority", temp_sql)
        self.assertIn("null::timestamptz as valid_from", no_fly_sql)
        self.assertIn("valid_from", temp_sql)
        self.assertIn("'2026-07-04T12:00:00Z'::timestamptz >= valid_from", temp_sql)

    def test_display_adapters_keep_terrain_lod_out_of_unified_route_planning_sources(self):
        args = default_args(terrain_lod_display=True)

        source_adapters = refresh.obstacle_source_adapters(args, has_terrain_tables=True)
        display_adapters = refresh.obstacle_display_adapters(args, has_terrain_tables=True)

        self.assertNotIn(args.terrain_lod_view_name, [adapter.view_name for adapter in source_adapters])
        self.assertEqual([adapter.view_name for adapter in display_adapters], [args.terrain_lod_view_name])
        text = sql_text(display_adapters[0].build_view_sql())
        self.assertIn(f'create materialized view "citydb_grid"."{args.terrain_lod_view_name}"', text)
        self.assertIn("lod_level", text)
        self.assertIn("display-only terrain LOD", display_adapters[0].description)


if __name__ == "__main__":
    unittest.main()
