from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OBSOLETE_ROLE_PATTERN = re.compile(
    r"\b(web_anon|web_admin|pgrst_anonymous|postgrest_authenticator|airspace_reader|flight_planner|airspace_admin)\b"
)


class PostgrestRoleMigrationScriptTests(unittest.TestCase):
    def test_airspace_refresh_worker_defaults_generated_object_grants_to_admin(self):
        script = (ROOT / "scripts" / "watch_airspace_refresh.py").read_text(encoding="utf-8")

        self.assertIn('parser.add_argument("--grant-role", default="admin"', script)
        self.assertNotIn('default="web_anon"', script)

    def test_refresh_scripts_and_ddl_no_longer_grant_to_removed_postgrest_roles(self):
        paths = [
            *(ROOT / "scripts").glob("*.py"),
            *(
                path
                for path in (ROOT / "backend").glob("*.sql")
                if path.name != "migrate_postgrest_api_roles.sql"
            ),
        ]

        offenders: list[str] = []
        for path in paths:
            text = path.read_text(encoding="utf-8")
            if OBSOLETE_ROLE_PATTERN.search(text):
                offenders.append(str(path.relative_to(ROOT)))

if __name__ == "__main__":
    unittest.main()


class SuitableFootprintApiTests(unittest.TestCase):
    def test_suitable_footprint_view_exposes_only_frontend_geojson_fields(self):
        script = (ROOT / "backend" / "migrate_postgrest_api_roles.sql").read_text(encoding="utf-8")

        self.assertIn("create or replace view api.suitable_fly_zone_footprints as", script)
        self.assertIn("select\n  id,\n  name,\n  geom\nfrom airspace.suitable_fly_zone", script)
        self.assertIn("comment on view api.suitable_fly_zone_footprints", script)
        self.assertIn("grant select on api.suitable_fly_zone_footprints to admin", script)

    def test_frontend_requests_suitable_footprints_as_geojson(self):
        module = (ROOT / "frontend" / "src" / "features" / "suitable-footprint" / "suitable-footprint-module.js").read_text(encoding="utf-8")

        self.assertIn("application/geo+json", module)
        self.assertIn("suitable_fly_zone_footprints", module)


if __name__ == "__main__":
    unittest.main()
