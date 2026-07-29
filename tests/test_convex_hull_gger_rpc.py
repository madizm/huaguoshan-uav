from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RPC = ROOT / "backend" / "create_convex_hull_gger_rpc.sql"


class ConvexHullGgerRpcTests(unittest.TestCase):
    def test_rpc_converts_geographic_polyhedral_surface_with_ibest(self):
        sql = RPC.read_text(encoding="utf-8")

        self.assertIn("ST_GeomFromText(p_wkt, 4326)", sql)
        self.assertIn("ST_AsGrids3D(v_geometry, p_detail_level, p_is_agg)", sql)
        self.assertIn("ST_WithBox(v_grids, 'GGER')", sql)
        self.assertIn("ST_AsText(v_grids, 'GGER')", sql)
        self.assertIn("ST_nCells(v_grids)", sql)
        self.assertIn("ST_GeometryType(v_geometry) <> 'ST_PolyhedralSurface'", sql)
        self.assertIn("p_detail_level not between 6 and 32", sql)
        self.assertIn("v_cell_count > p_max_cells", sql)

    def test_rpc_is_exposed_through_citydb_and_documented(self):
        sql = RPC.read_text(encoding="utf-8")

        self.assertIn("create or replace function api.grid_convex_hull_3d", sql)
        self.assertIn("comment on function public.grid_convex_hull_3d", sql)
        self.assertIn("返回 JSON", sql)
        self.assertIn("comment on function api.grid_convex_hull_3d", sql)
        self.assertIn("grant execute on function api.grid_convex_hull_3d", sql)
        self.assertIn("notify pgrst, 'reload schema'", sql)


if __name__ == "__main__":
    unittest.main()
