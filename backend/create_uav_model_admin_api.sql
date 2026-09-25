-- 无人机机型目录管理 API：型号规格只读视图与更新 RPC。
-- 依赖 create_uav_model_catalog.sql；可安全重复执行。

begin;

-- 一、机型目录只读视图：合并 device_model 基础信息与 uav_model_spec 规格。
create or replace view api.equipment_uav_models as
select 
  m.model_code,
  m.name,
  m.manufacturer,
  s.weight_class,
  s.max_takeoff_weight_kg,
  s.max_speed_kph,
  s.max_endurance_min,
  s.max_payload_kg
from equipment.device_model m
join equipment.uav_model_spec s on s.model_code = m.model_code
where m.category_code = 'uav';

comment on view api.equipment_uav_models is '无人机机型目录只读资源，包含型号基础信息与性能规格。';
comment on column api.equipment_uav_models.model_code is '型号唯一编码，如 DJI_MAVIC_3E。';
comment on column api.equipment_uav_models.weight_class is '重量分级：micro/light/small/medium/large。';
comment on column api.equipment_uav_models.max_takeoff_weight_kg is '最大起飞重量，单位千克。';
comment on column api.equipment_uav_models.max_speed_kph is '最大水平速度，单位千米每小时。';
comment on column api.equipment_uav_models.max_endurance_min is '最大续航时间，单位分钟。';
comment on column api.equipment_uav_models.max_payload_kg is '最大载荷重量，单位千克。';

-- 二、更新 RPC：允许修改型号名称、厂商和规格参数，不允许修改型号编码。
create or replace function api.update_equipment_uav_model(p_model_code text, p_changes jsonb)
returns void
language plpgsql
set search_path = api, equipment, public, pg_temp
as $$
begin
  -- 更新 device_model 基础信息
  update equipment.device_model set
    name = coalesce(nullif(p_changes->>'name', ''), name),
    manufacturer = case 
      when p_changes ? 'manufacturer' 
      then nullif(p_changes->>'manufacturer', '') 
      else manufacturer 
    end
  where model_code = p_model_code and category_code = 'uav';
  
  if not found then
    raise exception 'uav model % does not exist', p_model_code;
  end if;
  
  -- 更新 uav_model_spec 规格参数
  update equipment.uav_model_spec set
    weight_class = coalesce(nullif(p_changes->>'weight_class', ''), weight_class),
    max_takeoff_weight_kg = case 
      when p_changes ? 'max_takeoff_weight_kg' 
      then (p_changes->>'max_takeoff_weight_kg')::numeric 
      else max_takeoff_weight_kg 
    end,
    max_speed_kph = case 
      when p_changes ? 'max_speed_kph' 
      then nullif(p_changes->>'max_speed_kph', '')::numeric 
      else max_speed_kph 
    end,
    max_endurance_min = case 
      when p_changes ? 'max_endurance_min' 
      then nullif(p_changes->>'max_endurance_min', '')::integer 
      else max_endurance_min 
    end,
    max_payload_kg = case 
      when p_changes ? 'max_payload_kg' 
      then nullif(p_changes->>'max_payload_kg', '')::numeric 
      else max_payload_kg 
    end
  where model_code = p_model_code;
end $$;

comment on function api.update_equipment_uav_model(text, jsonb) is '按型号编码更新无人机型号名称、厂商和性能规格，不允许修改型号编码。';

-- 三、新增 RPC：创建新的无人机机型，同时插入 device_model 和 uav_model_spec。
create or replace function api.create_equipment_uav_model(
  p_model_code text,
  p_name text,
  p_manufacturer text,
  p_weight_class text,
  p_max_takeoff_weight_kg numeric,
  p_max_speed_kph numeric default null,
  p_max_endurance_min integer default null,
  p_max_payload_kg numeric default null
)
returns text
language plpgsql
set search_path = api, equipment, public, pg_temp
as $$
declare
  v_model_code text;
begin
  -- 验证输入
  if p_model_code is null or p_model_code = '' then
    raise exception '型号编码不能为空';
  end if;
  if p_name is null or p_name = '' then
    raise exception '型号名称不能为空';
  end if;
  if p_weight_class not in ('micro', 'light', 'small', 'medium', 'large') then
    raise exception '重量分级必须是 micro/light/small/medium/large 之一';
  end if;
  if p_max_takeoff_weight_kg is null or p_max_takeoff_weight_kg <= 0 then
    raise exception '最大起飞重量必须大于 0';
  end if;
  
  -- 插入 device_model
  insert into equipment.device_model (model_code, category_code, name, manufacturer)
  values (p_model_code, 'uav', p_name, p_manufacturer);
  
  -- 插入 uav_model_spec
  insert into equipment.uav_model_spec (
    model_code, weight_class, max_takeoff_weight_kg,
    max_speed_kph, max_endurance_min, max_payload_kg
  ) values (
    p_model_code, p_weight_class, p_max_takeoff_weight_kg,
    p_max_speed_kph, p_max_endurance_min, p_max_payload_kg
  );
  
  return p_model_code;
end $$;

comment on function api.create_equipment_uav_model(text, text, text, text, numeric, numeric, integer, numeric) is '创建新的无人机机型，返回型号编码。';

-- 四、权限控制
revoke all on function api.update_equipment_uav_model(text, jsonb) from public, anonymous;
revoke all on function api.create_equipment_uav_model(text, text, text, text, numeric, numeric, integer, numeric) from public, anonymous;
grant execute on function api.update_equipment_uav_model(text, jsonb) to admin;
grant execute on function api.create_equipment_uav_model(text, text, text, text, numeric, numeric, integer, numeric) to admin;
grant select on api.equipment_uav_models to admin;
grant select on equipment.device_model, equipment.uav_model_spec to admin;

notify pgrst, 'reload schema';
commit;
