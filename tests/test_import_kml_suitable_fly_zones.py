from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "import_kml_suitable_fly_zones.py"
spec = importlib.util.spec_from_file_location("import_kml_suitable_fly_zones", MODULE_PATH)
importer = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = importer
assert spec.loader is not None
spec.loader.exec_module(importer)


class KmlSuitableFlyZoneImportTests(unittest.TestCase):
    def test_source_kml_preserves_each_placemark_as_one_multipolygon(self):
        zones = importer.load_zones(Path(__file__).resolve().parents[1] / "data" / "shifeikongyu.kml")

        self.assertEqual(len(zones), 13)
        lianyungang = next(zone for zone in zones if zone.name == "连云港市")
        self.assertEqual(lianyungang.source_feature_id, "jssmerge.3")
        self.assertEqual(lianyungang.source_layer, "lianyungangshiDissolve")
        self.assertEqual(lianyungang.geometry["type"], "MultiPolygon")
        self.assertEqual(len(lianyungang.geometry["coordinates"]), 44)
        self.assertGreater(sum(len(polygon) - 1 for polygon in lianyungang.geometry["coordinates"]), 0)

    def test_parser_closes_rings_and_preserves_extended_data(self):
        kml = """<?xml version='1.0' encoding='UTF-8'?>
        <kml xmlns='http://www.opengis.net/kml/2.2'><Document><Placemark id='zone-1'>
          <name>备用名称</name><ExtendedData><SchemaData><SimpleData name='aliasname'>测试空域</SimpleData>
          <SimpleData name='layer'>test-layer</SimpleData></SchemaData></ExtendedData>
          <MultiGeometry><Polygon><outerBoundaryIs><LinearRing>
          <coordinates>118,34 119,34 118,35</coordinates>
          </LinearRing></outerBoundaryIs><innerBoundaryIs><LinearRing>
          <coordinates>118.1,34.1 118.2,34.1 118.1,34.2</coordinates>
          </LinearRing></innerBoundaryIs></Polygon></MultiGeometry>
        </Placemark></Document></kml>"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "zone.kml"
            path.write_text(kml, encoding="utf-8")
            zone = importer.load_zones(path)[0]

        self.assertEqual(zone.name, "测试空域")
        self.assertEqual(zone.source_layer, "test-layer")
        self.assertEqual(zone.source_properties["aliasname"], "测试空域")
        self.assertEqual(len(zone.geometry["coordinates"][0]), 2)
        self.assertEqual(zone.geometry["coordinates"][0][0][0], zone.geometry["coordinates"][0][0][-1])
        self.assertEqual(zone.geometry["coordinates"][0][1][0], zone.geometry["coordinates"][0][1][-1])


if __name__ == "__main__":
    unittest.main()
