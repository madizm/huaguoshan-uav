-- 无人机机型目录：型号级参数字典，支持风险评估的重量分级和性能参考。
-- 复用既有 device_model 型号字典模式，新增 uav_model_spec 强类型规格表。
-- 依赖 create_equipment_asset_schema.sql；可安全重复执行。

begin;

-- 一、无人机型号规格表：最小集参数，覆盖风险评估核心维度。
create table if not exists equipment.uav_model_spec (
  model_code text primary key references equipment.device_model(model_code) on delete cascade,
  weight_class text not null check (weight_class in ('micro', 'light', 'small', 'medium', 'large')),
  max_takeoff_weight_kg numeric not null check (max_takeoff_weight_kg > 0),
  max_speed_kph numeric check (max_speed_kph is null or max_speed_kph > 0),
  max_endurance_min integer check (max_endurance_min is null or max_endurance_min > 0),
  max_payload_kg numeric check (max_payload_kg is null or max_payload_kg >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table equipment.uav_model_spec is '无人机型号静态规格，来源为厂商产品资料或民航认证数据。';
comment on column equipment.uav_model_spec.model_code is '对应设备型号编码，关联 device_model 字典。';
comment on column equipment.uav_model_spec.weight_class is '重量分级：micro(<250g)、light(250g-4kg)、small(4-25kg)、medium(25-150kg)、large(>150kg)。';
comment on column equipment.uav_model_spec.max_takeoff_weight_kg is '最大起飞重量，单位千克，风险评估核心参数。';
comment on column equipment.uav_model_spec.max_speed_kph is '最大水平飞行速度，单位千米每小时。';
comment on column equipment.uav_model_spec.max_endurance_min is '最大续航时间，单位分钟。';
comment on column equipment.uav_model_spec.max_payload_kg is '最大载荷重量，单位千克。';

drop trigger if exists uav_model_spec_touch_updated_at on equipment.uav_model_spec;
create trigger uav_model_spec_touch_updated_at before update on equipment.uav_model_spec
for each row execute function equipment.touch_updated_at();

-- 二、预置大疆和道通机型数据（从开发环境数据库探测）。
insert into equipment.device_model (model_code, category_code, name, manufacturer) values
  ('DJI_MAVIC_3E', 'uav', 'DJI Mavic 3E', 'DJI'),
  ('DJI_MAVIC_3T', 'uav', 'DJI Mavic 3T', 'DJI'),
  ('DJI_M350_RTK', 'uav', 'DJI Matrice 350 RTK', 'DJI'),
  ('DJI_M30T', 'uav', 'DJI Matrice 30T', 'DJI'),
  ('AUTEL_EVO_MAX_4T', 'uav', 'Autel EVO Max 4T', 'Autel')
on conflict (model_code) do update set
  name = excluded.name,
  manufacturer = excluded.manufacturer;

insert into equipment.uav_model_spec (model_code, weight_class, max_takeoff_weight_kg, max_speed_kph, max_endurance_min, max_payload_kg) values
  ('DJI_MAVIC_3E', 'light', 1.05, 75.6, 45, null),
  ('DJI_MAVIC_3T', 'light', 1.05, 75.6, 45, null),
  ('DJI_M350_RTK', 'medium', 9.2, null, 55, 2.7),
  ('DJI_M30T', 'medium', 4.069, null, 41, null),
  ('AUTEL_EVO_MAX_4T', 'light', 1.999, null, 42, null)
on conflict (model_code) do update set
  weight_class = excluded.weight_class,
  max_takeoff_weight_kg = excluded.max_takeoff_weight_kg,
  max_speed_kph = excluded.max_speed_kph,
  max_endurance_min = excluded.max_endurance_min,
  max_payload_kg = excluded.max_payload_kg;

-- 三、更新现有无人机资产的 type_code，关联到机型目录。
update equipment.asset
set type_code = case
  when model = 'DJI Mavic 3E' then 'DJI_MAVIC_3E'
  when model = 'DJI Mavic 3T' then 'DJI_MAVIC_3T'
  when model = 'DJI Matrice 350 RTK' then 'DJI_M350_RTK'
  when model = 'DJI M30T' then 'DJI_M30T'
  when model = 'Autel EVO Max 4T' then 'AUTEL_EVO_MAX_4T'
  else type_code
end
where category_code = 'uav'
  and type_code is distinct from case
    when model = 'DJI Mavic 3E' then 'DJI_MAVIC_3E'
    when model = 'DJI Mavic 3T' then 'DJI_MAVIC_3T'
    when model = 'DJI Matrice 350 RTK' then 'DJI_M350_RTK'
    when model = 'DJI M30T' then 'DJI_M30T'
    when model = 'Autel EVO Max 4T' then 'AUTEL_EVO_MAX_4T'
    else type_code
  end;

commit;
