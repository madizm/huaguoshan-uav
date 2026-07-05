from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SQL_PATH = ROOT / "backend" / "create_flight_path_planning_rpc.sql"
MIGRATION_PATH = ROOT / "backend" / "migrate_postgrest_api_roles.sql"
WORKBENCH_PATH = ROOT / "js" / "FlightPathWorkbench.js"
DOC_PATH = ROOT / "docs" / "flight_path_planning_management_plan.md"


class FlightPathDomainLanguageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sql = SQL_PATH.read_text(encoding="utf-8")
        cls.migration_sql = MIGRATION_PATH.read_text(encoding="utf-8")
        cls.js = WORKBENCH_PATH.read_text(encoding="utf-8")
        cls.doc = DOC_PATH.read_text(encoding="utf-8")

    def test_sql_comments_name_workspace_and_result_without_business_flight_plan_semantics(self):
        self.assertIn("comment on schema flight_path is '技术路径规划工作区：保存路径规划方案、控制点和路径规划结果；不是业务飞行计划。';", self.sql)
        self.assertIn("is '创建一个路径规划方案/工作区，保存起终点和途径点控制输入；不是业务飞行计划。';", self.sql)
        self.assertIn("is '计算路径规划方案并保存一次路径规划结果；该结果不是实际飞行事实。';", self.sql)

    def test_frontend_copy_distinguishes_path_planning_scheme_from_business_flight_plan(self):
        self.assertIn("路径规划方案", self.js)
        self.assertIn("路径规划结果", self.js)
        self.assertIn("技术规划工作区，不是业务飞行计划", self.js)
        self.assertIn('aria-label="路径规划方案工作区"', self.js)
        self.assertNotIn("飞行路径方案", self.js)

    def test_api_comments_keep_compatibility_names_but_explain_path_planning_semantics(self):
        self.assertIn("comment on view api.flight_path_plans is '路径规划方案/技术规划工作区列表，不是业务飞行计划", self.migration_sql)
        self.assertIn("不是创建业务飞行计划", self.migration_sql)
        self.assertIn("有路径规划结果时应归档而不是物理删除", self.migration_sql)
        self.assertIn("comment on view api.flight_path_plan_results is '路径规划结果列表；每条记录是一次平台计算输出，不是实际飞行事实。';", self.migration_sql)
        self.assertNotIn("飞行路径规划方案", self.migration_sql)
        self.assertNotIn("路径计算结果", self.migration_sql)

    def test_api_documentation_warns_that_flight_path_plan_is_not_business_flight_plan(self):
        self.assertIn("`flight_path.plan` 是路径规划方案/路径规划工作区，不是业务飞行计划", self.doc)
        self.assertIn("`flight_path.plan_result` 是一次路径规划结果，不是实际飞行事实", self.doc)
        self.assertIn("PostgREST RPC 名称保留 `flight_path_plan` 兼容既有接口，但文档语义必须解释为路径规划方案", self.doc)

class FlightPathDeletionProtectionContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sql = SQL_PATH.read_text(encoding="utf-8").lower()

    def test_plan_results_are_not_cascade_deleted_with_path_planning_scheme(self):
        self.assertIn("flight_path_plan_result_plan_fk", self.sql)
        self.assertIn("foreign key (plan_id) references flight_path.plan(id) on delete restrict", self.sql)
        self.assertIn("archive_flight_path_plan", self.sql)
        self.assertIn("path planning results exist; archive the path planning scheme instead of deleting it", self.sql)


if __name__ == "__main__":
    unittest.main()
