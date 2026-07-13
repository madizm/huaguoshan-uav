from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "export_wg_airspace_3dtiles.py"
spec = importlib.util.spec_from_file_location("export_wg_airspace_3dtiles", MODULE_PATH)
exporter = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = exporter
assert spec.loader is not None
spec.loader.exec_module(exporter)


class WgAirspaceGgerTilesExportTests(unittest.TestCase):
    def test_gger_encoder_matches_documented_ibest_samples(self):
        self.assertEqual(exporter.encode_2d(116.315222, 39.910278, 15), "G001310322230230")
        self.assertEqual(
            exporter.encode_3d(116.315222, 39.910278, 100, 32),
            "GZ00262064446046062063523002211204",
        )

    def test_candidate_classification_uses_mutually_exclusive_w_and_g_bands(self):
        dem_samples = [100.0]

        w = exporter.classify_candidate(110.0, 150.0, dem_samples)
        boundary_mixed = exporter.classify_candidate(190.0, 230.0, dem_samples)
        g = exporter.classify_candidate(230.0, 280.0, dem_samples)

        self.assertEqual(w[0], "W")
        self.assertEqual(w[5:7], (0.0, 120.0))
        self.assertEqual(boundary_mixed[0], "MIXED")
        self.assertTrue(boundary_mixed[4])
        self.assertEqual(g[0], "G")
        self.assertEqual(g[5:7], (120.0, 300.0))

    def test_height_layer_bounds_are_monotonic_and_cover_input_height(self):
        bounds = exporter.get_height_bounds(120.0, 20)

        self.assertLess(bounds.min_height, bounds.max_height)
        self.assertLessEqual(bounds.min_height, 120.0)
        self.assertGreaterEqual(bounds.max_height, 120.0)
        self.assertGreater(bounds.max_layer_exclusive, bounds.min_layer)

    def test_horizontal_cell_bounds_reencode_to_same_gger_2d_code(self):
        cell = exporter.get_cell_bounds(119.26, 34.64, 20)
        code_from_input = exporter.encode_2d(119.26, 34.64, 20)
        code_from_center = exporter.encode_2d(cell.center_lon, cell.center_lat, 20)

        self.assertEqual(code_from_input, code_from_center)
        self.assertLess(cell.west, cell.east)
        self.assertLess(cell.south, cell.north)



class DemWindowSamplingTests(unittest.TestCase):
    def test_dem_sampling_returns_empty_for_gger_cells_outside_raster_window(self):
        class FakeWindow:
            def round_offsets(self):
                return self

            def round_lengths(self):
                return self

            def intersection(self, _other):
                raise RuntimeError("Intersection is empty")

        class FakeTransformer:
            def transform(self, xs, ys):
                return xs, ys

        class FakeTransformerFactory:
            @staticmethod
            def from_crs(_src_crs, _dst_crs, always_xy=True):
                return FakeTransformer()

        class FakeSource:
            crs = "EPSG:4326"
            transform = object()
            bounds = (0, 0, 1, 1)

            def window(self, *_bounds):
                return object()

        cell = exporter.CellBounds(
            west=118.36,
            south=33.91,
            east=118.37,
            north=33.92,
            center_lon=118.365,
            center_lat=33.915,
            min_x=0,
            min_y=0,
            max_x=1,
            max_y=1,
        )

        samples = exporter.dem_samples_for_cell(
            FakeSource(),
            cell,
            sample_step=1,
            max_samples=16,
            np=None,
            Transformer=FakeTransformerFactory,
            from_bounds=lambda *_args, **_kwargs: FakeWindow(),
        )

        self.assertEqual(samples, [])


if __name__ == "__main__":
    unittest.main()
