#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# ///
"""Static contract checks for the Scalar documentation portal.

The documentation portal is a browser-delivered public seam: these tests assert
that the shipped page shares the frontend token convention and requests protected
PostgREST documentation with the stored admin JWT rather than granting anonymous
business access.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCS_HTML = ROOT / "deploy" / "docs" / "index.html"
NGINX_CONF = ROOT / "deploy" / "nginx.conf"


class DocsPortalContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.html = DOCS_HTML.read_text(encoding="utf-8")

    def test_docs_portal_shares_frontend_token_storage_key(self):
        self.assertIn("var TOKEN_KEY = 'postgrest.jwt';", self.html)
        self.assertIn("localStorage.getItem(TOKEN_KEY)", self.html)
        self.assertIn("localStorage.setItem(TOKEN_KEY, val)", self.html)

    def test_auth_openapi_is_loaded_anonymously(self):
        self.assertIn("fetch('/openapi.json'", self.html)
        self.assertIn("renderAuthReference", self.html)
        self.assertNotIn("fetch('/openapi.json', { headers", self.html)

    def test_postgrest_openapi_is_loaded_with_stored_admin_jwt_when_present(self):
        self.assertIn("fetch('/postgrest/'", self.html)
        self.assertIn("postgrestOpenApiHeaders()", self.html)
        self.assertIn("'Accept': 'application/openapi+json'", self.html)
        self.assertIn("headers['Authorization'] = 'Bearer ' + token", self.html)

    def test_postgrest_scalar_reference_uses_prefetched_spec_and_bearer_try_it(self):
        self.assertIn("spec: { content: postgrestSpec }", self.html)
        self.assertIn("injectBearerSecurity(postgrestSpec)", self.html)
        self.assertIn("preferredSecurityScheme: 'bearerAuth'", self.html)
        self.assertIn("token: token", self.html)
    def test_postgrest_server_url_is_rewritten_to_unified_entry_point(self):
        self.assertIn("entrypointUrl('/postgrest')", self.html)
        self.assertIn("delete spec.host;", self.html)
        self.assertIn("delete spec.basePath;", self.html)
        self.assertIn("delete spec.schemes;", self.html)
        self.assertNotIn("0.0.0.0:13000", self.html)

    def test_anonymous_or_empty_postgrest_view_is_explained(self):
        self.assertIn("匿名用户看到的是空白 OpenAPI 文档", self.html)
        self.assertIn("PostgREST OpenAPI 当前没有暴露业务路径", self.html)

    def test_scalar_documentation_area_uses_full_page_width_and_internal_scroll(self):
        self.assertIn("width: 100%;", self.html)
        self.assertIn("max-width: none;", self.html)
        self.assertIn("#scalarAuthRef,", self.html)
        self.assertIn("#scalarPgrstRef", self.html)
        self.assertIn("height: clamp(620px, calc(100vh - 220px), 1100px);", self.html)
        self.assertIn("overflow: auto;", self.html)
        self.assertNotIn("max-width: 700px;", self.html)
        self.assertNotIn("overflow: hidden;", self.html)
    def test_portal_card_heading_styles_do_not_leak_into_scalar_content(self):
        self.assertIn(".card > h2", self.html)
        self.assertIn(".card > p", self.html)
        self.assertNotIn(".card h2 {", self.html)


class NginxDocsRoutingContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.conf = NGINX_CONF.read_text(encoding="utf-8")

    def test_unified_entry_point_serves_frontend_and_scalar_docs(self):
        self.assertIn("location / {", self.conf)
        self.assertIn("/frontend/tianditu-3d.html", self.conf)
        self.assertIn("location /docs/ {", self.conf)
        self.assertIn("alias /mnt/project/huaguoshan/deploy/docs/;", self.conf)
        self.assertIn("try_files $uri $uri/ /docs/index.html;", self.conf)

if __name__ == "__main__":
    unittest.main()
