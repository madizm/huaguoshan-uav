#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# ///
"""Static contract checks for the deployment-level Nginx smoke test.

The executable smoke test targets a deployed stack, so this file keeps the
repository contract testable without live services: the script must exercise all
externally observable checks required by issue #12, and the operator-facing run
book must document the inputs and likely failure modes.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SMOKE_SCRIPT = ROOT / "tests" / "test_nginx_e2e_smoke.py"
RUNBOOK = ROOT / "docs" / "nginx-e2e-smoke-test.md"


class NginxE2ESmokeScriptContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script = SMOKE_SCRIPT.read_text(encoding="utf-8")

    def test_targets_unified_nginx_entry_point_paths(self):
        self.assertIn("NGINX_HOST", self.script)
        self.assertIn("/healthz", self.script)
        self.assertIn("/auth/login", self.script)
        self.assertIn("/auth/me", self.script)
        self.assertIn("/postgrest/", self.script)
        self.assertIn("/docs/", self.script)

    def test_verifies_scalar_portal_and_openapi_documents(self):
        self.assertIn("Scalar documentation portal", self.script)
        self.assertIn("GET /docs/", self.script)
        self.assertIn('"Accept": "application/openapi+json"', self.script)
        self.assertIn("Authenticated OpenAPI has expected business paths", self.script)
        self.assertIn("missing_paths", self.script)

    def test_uses_configured_credentials_and_business_probe_endpoints(self):
        self.assertIn("SMOKE_TEST_USERNAME", self.script)
        self.assertIn("SMOKE_TEST_PASSWORD", self.script)
        self.assertIn("SMOKE_TEST_BUSINESS_ENDPOINTS", self.script)
        self.assertIn("configured protected business endpoint", self.script)


class NginxE2ESmokeRunbookContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.runbook = RUNBOOK.read_text(encoding="utf-8")

    def test_documents_required_inputs(self):
        self.assertIn("NGINX_HOST", self.runbook)
        self.assertIn("SMOKE_TEST_USERNAME", self.runbook)
        self.assertIn("SMOKE_TEST_PASSWORD", self.runbook)
        self.assertIn("SMOKE_TEST_BUSINESS_ENDPOINTS", self.runbook)

    def test_documents_expected_failure_modes(self):
        self.assertIn("Expected failure modes", self.runbook)
        self.assertIn("/healthz", self.runbook)
        self.assertIn("anonymous PostgREST", self.runbook)
        self.assertIn("PostgREST OpenAPI", self.runbook)
        self.assertIn("/docs/", self.runbook)


if __name__ == "__main__":
    unittest.main()
