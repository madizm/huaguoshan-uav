import unittest
from pathlib import Path
from urllib.parse import urljoin


ROOT = Path(__file__).resolve().parents[1]


class FrontendRelativeApiPathContractTest(unittest.TestCase):
    def test_api_defaults_are_relative_to_legacy_frontend_directory(self):
        expected_defaults = {
            "frontend/src/config/runtime-config.js": (
                "baseUrl: '../postgrest'",
                "loginUrl: '../auth/login'",
                "meUrl: '../auth/me'",
            ),
            "frontend/src/api/postgrest-client.js": (
                "|| '../postgrest'",
                "|| '../auth/login'",
                "|| '../auth/me'",
            ),
            "frontend/src/app/create-huaguoshan-app.js": (
                "|| '../postgrest'",
                "|| '../auth/login'",
                "|| '../auth/me'",
            ),
        }

        for relative_path, defaults in expected_defaults.items():
            source = (ROOT / relative_path).read_text(encoding="utf-8")
            with self.subTest(path=relative_path):
                for default in defaults:
                    self.assertIn(default, source)

    def test_relative_paths_work_with_direct_and_prefixed_entry_points(self):
        entry_points = {
            "https://internal.example/frontend/tianditu-3d.html": (
                "https://internal.example/postgrest/rpc/example",
                "https://internal.example/auth/login",
            ),
            "https://public.example/lianyugang-uav/frontend/tianditu-3d.html": (
                "https://public.example/lianyugang-uav/postgrest/rpc/example",
                "https://public.example/lianyugang-uav/auth/login",
            ),
        }

        for page_url, (expected_rpc, expected_login) in entry_points.items():
            with self.subTest(page_url=page_url):
                self.assertEqual(urljoin(page_url, "../postgrest/rpc/example"), expected_rpc)
                self.assertEqual(urljoin(page_url, "../auth/login"), expected_login)


if __name__ == "__main__":
    unittest.main()
