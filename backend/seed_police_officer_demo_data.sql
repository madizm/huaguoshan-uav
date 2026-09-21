-- 开发环境警员演示数据。
-- 所有记录均通过 is_simulated=true 和 metadata.simulated=true 明确标记为模拟数据；按警号幂等写入。

begin;

insert into emergency_resource.police_officer (
  officer_no,
  name,
  contact_phone,
  organization_name,
  availability_status,
  is_active,
  is_simulated,
  metadata
) values
  ('SIM-POLICE-001', '演示警员01', '13800002001', '连云港市公安局海州分局', 'available',   true, true, '{"simulated":true,"seed":"police_officer_demo"}'::jsonb),
  ('SIM-POLICE-002', '演示警员02', '13800002002', '连云港市公安局海州分局', 'on_duty',    true, true, '{"simulated":true,"seed":"police_officer_demo"}'::jsonb),
  ('SIM-POLICE-003', '演示警员03', '13800002003', '连云港市公安局海州分局', 'available',  true, true, '{"simulated":true,"seed":"police_officer_demo"}'::jsonb),
  ('SIM-POLICE-004', '演示警员04', '13800002004', '连云港市公安局海州分局', 'dispatched', true, true, '{"simulated":true,"seed":"police_officer_demo"}'::jsonb),
  ('SIM-POLICE-005', '演示警员05', '13800002005', '连云港市公安局连云分局', 'available',  true, true, '{"simulated":true,"seed":"police_officer_demo"}'::jsonb),
  ('SIM-POLICE-006', '演示警员06', '13800002006', '连云港市公安局连云分局', 'on_duty',    true, true, '{"simulated":true,"seed":"police_officer_demo"}'::jsonb),
  ('SIM-POLICE-007', '演示警员07', '13800002007', '连云港市公安局连云分局', 'leave',      true, true, '{"simulated":true,"seed":"police_officer_demo"}'::jsonb),
  ('SIM-POLICE-008', '演示警员08', '13800002008', '连云港市公安局连云分局', 'available',  true, true, '{"simulated":true,"seed":"police_officer_demo"}'::jsonb),
  ('SIM-POLICE-009', '演示警员09', '13800002009', '连云港市公安局赣榆分局', 'on_duty',    true, true, '{"simulated":true,"seed":"police_officer_demo"}'::jsonb),
  ('SIM-POLICE-010', '演示警员10', '13800002010', '连云港市公安局赣榆分局', 'unavailable',true, true, '{"simulated":true,"seed":"police_officer_demo"}'::jsonb)
on conflict (officer_no) do update set
  name = excluded.name,
  contact_phone = excluded.contact_phone,
  organization_name = excluded.organization_name,
  availability_status = excluded.availability_status,
  is_active = excluded.is_active,
  is_simulated = excluded.is_simulated,
  metadata = excluded.metadata;

commit;
