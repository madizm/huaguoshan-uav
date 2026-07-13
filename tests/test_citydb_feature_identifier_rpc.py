from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RPC_PATHS = [
    ROOT / "backend" / "create_citydb_feature_gger_grids_rpc.sql",
    ROOT / "backend" / "create_citydb_feature_properties_rpc.sql",
]
SAFE_NUMERIC_FEATURE_ID_MATCH = """f.id = case
            when p_feature_identifier ~ '^[0-9]+$'
                then p_feature_identifier::bigint
            else null::bigint
       end"""


class CitydbFeatureIdentifierRpcTests(unittest.TestCase):
    def test_non_numeric_identifiers_do_not_cast_to_bigint(self):
        for path in RPC_PATHS:
            sql = path.read_text(encoding="utf-8")
            self.assertIn(SAFE_NUMERIC_FEATURE_ID_MATCH, sql, path.name)
            self.assertNotIn(
                "p_feature_identifier ~ '^[0-9]+$'\n"
                "            and f.id = p_feature_identifier::bigint",
                sql,
                path.name,
            )


if __name__ == "__main__":
    unittest.main()
