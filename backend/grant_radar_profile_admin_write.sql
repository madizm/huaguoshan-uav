-- 兼容迁移：撤回雷达 profile 的直接 HTTP 写权限。
-- 后台应使用 create_equipment_admin_api.sql 提供的事务 RPC，避免产生半成品资产。
-- 依赖 create_equipment_admin_api.sql；可安全重复执行。

begin;

revoke insert, update, delete on api.equipment_microwave_radar_profiles from admin;
grant execute on function api.save_microwave_radar_configuration(jsonb, jsonb, timestamptz) to admin;
comment on view api.equipment_microwave_radar_profiles is '微波雷达设备专业属性只读资源，写入使用事务配置 RPC。';

notify pgrst, 'reload schema';
commit;
