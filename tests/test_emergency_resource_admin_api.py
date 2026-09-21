from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class EmergencyResourceAdminApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql = (ROOT / 'backend/create_emergency_resource_admin_api.sql').read_text(encoding='utf-8').lower()

    def test_unified_view_excludes_historical_rescue_force(self):
        self.assertIn('create or replace view api.emergency_resource_admin_details', self.sql)
        body = self.sql.split('create or replace view api.emergency_resource_admin_details', 1)[1].split('comment on view', 1)[0]
        self.assertNotIn('from emergency_resource.rescue_force', body)
        self.assertIn('emergency_rescue_forces_history', self.sql)

    def test_realtime_statistics_and_read_only_history(self):
        self.assertIn('create or replace view api.emergency_resource_admin_statistics', self.sql)
        self.assertIn('revoke insert,update,delete on api.emergency_rescue_forces', self.sql)
        self.assertIn('grant select on api.emergency_rescue_forces_history', self.sql)


if __name__ == '__main__':
    unittest.main()
