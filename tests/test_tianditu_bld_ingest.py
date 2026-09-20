from __future__ import annotations

import importlib.util
import math
from pathlib import Path
import sys
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "tianditu_bld" / "ingest_tiles.py"
spec = importlib.util.spec_from_file_location("ingest_tianditu_bld_tiles", MODULE_PATH)
ingester = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = ingester
assert spec.loader is not None
spec.loader.exec_module(ingester)


class TiandituBuildingTileIngestTests(unittest.TestCase):
    def test_tile_transformer_maps_raw_mvt_corners_to_tms_bounds(self):
        z, x, y, extent = 16, 54466, 22680, 4096
        span = 360.0 / 2**z
        west = -180.0 + x * span
        east = west + span
        south = -90.0 + y * span
        north = south + span
        transform = ingester.tile_transformer(z, x, y, extent)

        self.assertEqual(transform(0, 0), (west, north))
        transformed_east, transformed_south = transform(extent, extent)
        self.assertTrue(math.isclose(transformed_east, east, abs_tol=1e-12))
        self.assertTrue(math.isclose(transformed_south, south, abs_tol=1e-12))

    def test_decoder_preserves_raw_downward_mvt_y_axis(self):
        decoded = {"BLD": {"extent": 4096, "features": []}}
        with mock.patch.object(ingester.mapbox_vector_tile, "decode", return_value=decoded) as decode:
            result = ingester.decode_tile(b"tile")

        self.assertIs(result, decoded)
        decode.assert_called_once_with(
            b"tile",
            default_options={"y_coord_down": True},
        )


if __name__ == "__main__":
    unittest.main()
