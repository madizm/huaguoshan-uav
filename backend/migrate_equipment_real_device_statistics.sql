-- 依赖 create_equipment_asset_schema.sql 和 migrate_equipment_detection_devices.sql。
-- 仅统计非模拟设备；模拟资产或使用模拟位置的资产均不参与统计。
begin;
set local lock_timeout = '10s';
set local statement_timeout = '60s';

create or replace view api.equipment_statistics as
select a.category_code, coalesce(s.connectivity_status, 'unknown') as connectivity_status,
       coalesce(s.dispatch_status, 'unknown') as dispatch_status, count(*)::bigint as asset_count
from equipment.asset a
left join equipment.asset_status_current s on s.asset_id = a.id
where a.is_simulated = false
group by a.category_code, coalesce(s.connectivity_status, 'unknown'), coalesce(s.dispatch_status, 'unknown');

create or replace view api.equipment_online_statistics as
select
  a.category_code,
  count(*)::bigint as total_count,
  count(*) filter (where s.connectivity_status = 'online')::bigint as online_count,
  round(
    count(*) filter (where s.connectivity_status = 'online') * 100.0 / nullif(count(*), 0),
    2
  )::numeric(5, 2) as online_rate,
  c.name as catalog_name
from equipment.asset a
join equipment.asset_category c on c.code = a.category_code
left join equipment.asset_status_current s on s.asset_id = a.id
where a.is_simulated = false
group by a.category_code, c.name;

comment on view api.equipment_statistics is '仅统计非模拟设备，按类别、连接状态和调度状态分组的设备统计资源。';
comment on view api.equipment_online_statistics is '仅统计非模拟设备，按设备类别统计设备总数、类别名称、在线设备数和在线率的只读资源。';

notify pgrst, 'reload schema';
commit;
