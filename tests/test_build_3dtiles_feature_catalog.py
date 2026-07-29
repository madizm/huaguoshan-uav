from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "build_3dtiles_feature_catalog.py"
TILESET = ROOT / "exports" / "citydb-3dtiler" / "huaguoshan_3dtiles" / "tileset.json"


class Build3dTilesFeatureCatalogTests(unittest.TestCase):
    def test_builds_identifier_to_content_index_from_structural_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "feature-catalog.json"
            subprocess.run(
                ["python3", str(SCRIPT), "--tileset", str(TILESET), "--output", str(output)],
                check=True,
                cwd=ROOT,
            )
            catalog = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(catalog["version"], 1)
        self.assertEqual(catalog["featureCount"], 17)
        self.assertEqual(catalog["contentCount"], 1)
        self.assertEqual(catalog["tileTransform"], json.loads(TILESET.read_text())["root"]["transform"])
        self.assertEqual(catalog["gltfUpAxis"], "Y")
        self.assertEqual(
            catalog["features"]["osm:way:1002427134"],
            ["content/0_0_0.glb"],
        )
        self.assertEqual(
            catalog["features"]["https://www.openstreetmap.org/way/1002427134"],
            ["content/0_0_0.glb"],
        )


if __name__ == "__main__":
    unittest.main()
