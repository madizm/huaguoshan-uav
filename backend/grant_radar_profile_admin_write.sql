-- 设备管理后台（frontend/admin）需要的写权限补充。
-- api.equipment_microwave_radar_profiles 为 select * 自动可更新视图，仅缺授权。
-- 依赖 migrate_microwave_radar_model_spec.sql；可安全重复执行。

begin;

grant insert, update, delete on api.equipment_microwave_radar_profiles to admin;
comment on view api.equipment_microwave_radar_profiles is '微波雷达设备专业属性 CRUD 资源，含型号、部署姿态与网络接入。';

notify pgrst, 'reload schema';
commit;
