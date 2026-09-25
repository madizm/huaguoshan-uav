-- 扩展无人机机型目录并创建别名映射表，支持观测数据中的机型名称匹配。
-- 依赖 create_uav_model_catalog.sql；可安全重复执行。

begin;

-- 一、补充常见机型到目录（基于观测数据中出现的高频机型）。
insert into equipment.device_model (model_code, category_code, name, manufacturer) values
  -- Mavic 系列
  ('DJI_MAVIC_4_PRO', 'uav', 'DJI Mavic 4 Pro', 'DJI'),
  ('DJI_MAVIC_3_PRO', 'uav', 'DJI Mavic 3 Pro', 'DJI'),
  ('DJI_MAVIC_2', 'uav', 'DJI Mavic 2', 'DJI'),
  ('DJI_MAVIC_AIR_2', 'uav', 'DJI Mavic Air 2', 'DJI'),
  ('DJI_MAVIC_O3', 'uav', 'DJI Mavic (O3)', 'DJI'),
  -- Air 系列
  ('DJI_AIR_3S', 'uav', 'DJI Air 3S', 'DJI'),
  ('DJI_AIR_3', 'uav', 'DJI Air 3', 'DJI'),
  ('DJI_AIR_2S', 'uav', 'DJI Air 2S', 'DJI'),
  -- Mini 系列
  ('DJI_MINI_5_PRO', 'uav', 'DJI Mini 5 Pro', 'DJI'),
  ('DJI_MINI_4_PRO', 'uav', 'DJI Mini 4 Pro', 'DJI'),
  ('DJI_MINI_3_PRO', 'uav', 'DJI Mini 3 Pro', 'DJI'),
  ('DJI_MINI_3', 'uav', 'DJI Mini 3', 'DJI'),
  ('DJI_MINI_2', 'uav', 'DJI Mini 2', 'DJI'),
  ('DJI_MINI_2_SE', 'uav', 'DJI Mini 2 SE', 'DJI'),
  ('DJI_MINI_4K', 'uav', 'DJI Mini 4K', 'DJI'),
  -- Matrice 系列
  ('DJI_MATRICE_4TD', 'uav', 'DJI Matrice 4TD', 'DJI'),
  ('DJI_MATRICE_4E_4T', 'uav', 'DJI Matrice 4E/4T', 'DJI'),
  ('DJI_MATRICE_3D_3TD', 'uav', 'DJI Matrice 3D/3TD', 'DJI'),
  -- 其他系列
  ('DJI_NEO_2', 'uav', 'DJI Neo 2', 'DJI'),
  ('DJI_NEO', 'uav', 'DJI Neo', 'DJI'),
  ('DJI_AVATA_2', 'uav', 'DJI Avata 2', 'DJI'),
  ('DJI_FLIP', 'uav', 'DJI Flip', 'DJI')
on conflict (model_code) do update set
  name = excluded.name,
  manufacturer = excluded.manufacturer;

-- 插入规格参数
insert into equipment.uav_model_spec (model_code, weight_class, max_takeoff_weight_kg, max_speed_kph, max_endurance_min, max_payload_kg) values
  -- Mavic 系列
  ('DJI_MAVIC_4_PRO', 'light', 1.063, 75.6, 51, null),
  ('DJI_MAVIC_3_PRO', 'light', 0.958, 75.6, 43, null),
  ('DJI_MAVIC_2', 'light', 0.907, 72.0, 31, null),
  ('DJI_MAVIC_AIR_2', 'light', 0.570, 68.4, 34, null),
  ('DJI_MAVIC_O3', 'light', 0.900, 68.4, 31, null),
  -- Air 系列
  ('DJI_AIR_3S', 'light', 0.724, 75.6, 45, null),
  ('DJI_AIR_3', 'light', 0.720, 75.6, 46, null),
  ('DJI_AIR_2S', 'light', 0.595, 68.4, 31, null),
  -- Mini 系列
  ('DJI_MINI_5_PRO', 'micro', 0.2499, 57.6, 40, null),
  ('DJI_MINI_4_PRO', 'micro', 0.249, 57.6, 34, null),
  ('DJI_MINI_3_PRO', 'micro', 0.249, 57.6, 34, null),
  ('DJI_MINI_3', 'micro', 0.249, 57.6, 38, null),
  ('DJI_MINI_2', 'micro', 0.242, 46.8, 31, null),
  ('DJI_MINI_2_SE', 'micro', 0.249, 46.8, 31, null),
  ('DJI_MINI_4K', 'micro', 0.249, 57.6, 31, null),
  -- Matrice 系列
  ('DJI_MATRICE_4TD', 'medium', 2.090, 54.0, 43, null),
  ('DJI_MATRICE_4E_4T', 'medium', 2.090, 54.0, 43, null),
  ('DJI_MATRICE_3D_3TD', 'medium', 1.610, 54.0, 50, null),
  -- 其他系列
  ('DJI_NEO_2', 'micro', 0.160, 43.2, 28, null),
  ('DJI_NEO', 'micro', 0.135, 43.2, 18, null),
  ('DJI_AVATA_2', 'light', 0.377, 97.2, 23, null),
  ('DJI_FLIP', 'micro', 0.249, 43.2, 25, null)
on conflict (model_code) do update set
  weight_class = excluded.weight_class,
  max_takeoff_weight_kg = excluded.max_takeoff_weight_kg,
  max_speed_kph = excluded.max_speed_kph,
  max_endurance_min = excluded.max_endurance_min,
  max_payload_kg = excluded.max_payload_kg;

-- 二、创建机型别名映射表，处理观测数据中的名称变体。
create table if not exists equipment.uav_model_alias (
  alias_pattern text primary key,
  model_code text not null references equipment.device_model(model_code) on delete cascade,
  priority integer not null default 0,
  created_at timestamptz not null default now()
);
comment on table equipment.uav_model_alias is '无人机机型别名映射表，支持模糊匹配观测数据中的机型名称。';
comment on column equipment.uav_model_alias.alias_pattern is '别名模式，支持 SQL LIKE 通配符（% 和 _）。';
comment on column equipment.uav_model_alias.model_code is '对应的标准型号编码。';
comment on column equipment.uav_model_alias.priority is '匹配优先级，数值越大优先级越高，用于处理多个模式匹配同一名称的情况。';

-- 插入别名映射规则（按优先级排序，高优先级先匹配）
insert into equipment.uav_model_alias (alias_pattern, model_code, priority) values
  -- Mavic 4 Pro / Mavic-O4
  ('%Mavic-O4%', 'DJI_MAVIC_4_PRO', 10),
  ('%Mavic 4 Pro%', 'DJI_MAVIC_4_PRO', 10),
  ('%Mavic4 pro%', 'DJI_MAVIC_4_PRO', 10),
  ('%Mavic(O4)%', 'DJI_MAVIC_4_PRO', 10),
  
  -- Matrice 4TD
  ('%Matrice 4TD%', 'DJI_MATRICE_4TD', 10),
  ('%100-Matrice 4TD%', 'DJI_MATRICE_4TD', 10),
  
  -- Matrice 4E/4T
  ('%Matrice 4E/4T%', 'DJI_MATRICE_4E_4T', 10),
  
  -- Matrice 3D/3TD
  ('%Matrice 3D/3TD%', 'DJI_MATRICE_3D_3TD', 10),
  ('%Matrice 3D%', 'DJI_MATRICE_3D_3TD', 9),
  ('%DJl Matrice 3D%', 'DJI_MATRICE_3D_3TD', 10),
  
  -- Matrice 350 RTK
  ('%M350 RTK%', 'DJI_M350_RTK', 10),
  ('%M350%', 'DJI_M350_RTK', 8),
  ('%Matrice 350%', 'DJI_M350_RTK', 10),
  
  -- Mavic 3E/3T/3M
  ('%Mavic 3E/3T/3M%', 'DJI_MAVIC_3E', 10),
  ('%Mavic 3E%', 'DJI_MAVIC_3E', 9),
  ('%Mavic 3T%', 'DJI_MAVIC_3T', 9),
  
  -- Mavic 3 Pro
  ('%Mavic 3 Pro%', 'DJI_MAVIC_3_PRO', 10),
  
  -- Mavic Air 2
  ('%58-Mavic Air 2%', 'DJI_MAVIC_AIR_2', 10),
  ('%Mavic Air 2%', 'DJI_MAVIC_AIR_2', 9),
  
  -- Mavic 2
  ('%41-Mavic 2%', 'DJI_MAVIC_2', 10),
  ('%Mavic 2%', 'DJI_MAVIC_2', 8),
  
  -- Mavic (O3)
  ('%Mavic(O3)%', 'DJI_MAVIC_O3', 10),
  
  -- Air 3S
  ('%Air 3s%', 'DJI_AIR_3S', 10),
  ('%AIR 3S%', 'DJI_AIR_3S', 10),
  
  -- Air 3
  ('%Air 3%', 'DJI_AIR_3', 9),
  ('%90-AIR 3%', 'DJI_AIR_3', 10),
  
  -- Air 2S
  ('%66-Air 2S%', 'DJI_AIR_2S', 10),
  ('%Air 2S%', 'DJI_AIR_2S', 9),
  
  -- Mini 5 Pro
  ('%Mini5 pro%', 'DJI_MINI_5_PRO', 10),
  ('%Mini 5 Pro%', 'DJI_MINI_5_PRO', 10),
  
  -- Mini 4 Pro
  ('%Mini 4 Pro%', 'DJI_MINI_4_PRO', 10),
  
  -- Mini 3 Pro
  ('%73-Mini 3 Pro%', 'DJI_MINI_3_PRO', 10),
  ('%Mini 3 Pro%', 'DJI_MINI_3_PRO', 9),
  
  -- Mini 3
  ('%87-Mini 3%', 'DJI_MINI_3', 10),
  ('%Mini3%', 'DJI_MINI_3', 10),
  ('%Mini 3%', 'DJI_MINI_3', 8),
  
  -- Mini 2
  ('%63-Mini 2%', 'DJI_MINI_2', 10),
  ('%Mini 2%', 'DJI_MINI_2', 9),
  
  -- Mini 2 SE
  ('%88-Mini2 SE%', 'DJI_MINI_2_SE', 10),
  ('%Mini2 SE%', 'DJI_MINI_2_SE', 10),
  
  -- Mini 4K
  ('%107-Mini 4K%', 'DJI_MINI_4K', 10),
  ('%Mini4K%', 'DJI_MINI_4K', 10),
  ('%Mini 4K%', 'DJI_MINI_4K', 10),
  
  -- Neo 2
  ('%DJI Neo 2%', 'DJI_NEO_2', 10),
  ('%Neo 2%', 'DJI_NEO_2', 9),
  
  -- Neo
  ('%Neo%', 'DJI_NEO', 7),
  
  -- Avata 2
  ('%Avata 2%', 'DJI_AVATA_2', 10),
  
  -- Flip
  ('%Flip%', 'DJI_FLIP', 10)
on conflict (alias_pattern) do update set
  model_code = excluded.model_code,
  priority = excluded.priority;

-- 三、创建机型匹配函数。
create or replace function equipment.match_uav_model(p_observation_model text)
returns text
language plpgsql
stable
set search_path = equipment, public, pg_temp
as $$
declare
  v_model_code text;
begin
  if p_observation_model is null or p_observation_model = '' then
    return null;
  end if;
  
  -- 使用别名映射表进行模糊匹配，按优先级排序取第一个
  select a.model_code into v_model_code
  from equipment.uav_model_alias a
  where p_observation_model ilike a.alias_pattern
  order by a.priority desc, a.alias_pattern
  limit 1;
  
  return v_model_code;
end $$;
comment on function equipment.match_uav_model(text) is '根据观测数据中的机型名称，匹配到标准机型目录，返回 model_code 或 null。';

-- 四、创建辅助视图：观测数据机型匹配统计。
create or replace view api.uav_model_match_statistics as
select
  o.model as observation_model,
  count(*) as observation_count,
  equipment.match_uav_model(o.model) as matched_model_code,
  case when equipment.match_uav_model(o.model) is not null then 'matched' else 'unmatched' end as match_status
from situation.target_observation o
where o.model is not null and o.model != ''
group by o.model;
comment on view api.uav_model_match_statistics is '观测数据机型匹配统计视图，用于评估匹配效果。';

-- 五、权限控制。
grant select on api.uav_model_match_statistics to admin;
grant select on equipment.uav_model_alias to admin;
grant execute on function equipment.match_uav_model(text) to admin;

notify pgrst, 'reload schema';
commit;
