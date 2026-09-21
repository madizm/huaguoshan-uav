-- 应急资源后台统一只读台账与实时统计；rescue_force 作为历史类别不纳入。
begin;

create or replace view api.emergency_resource_admin_details as
select 'medical_resource'::text category_code,id resource_id,source_code,name,unit_name managing_unit_name,contact_phone,availability_status,is_simulated,ST_X(geom) longitude,ST_Y(geom) latitude,to_jsonb(t)-array['id','source_code','name','unit_name','contact_phone','availability_status','is_simulated','geom','created_at','updated_at'] details,created_at,updated_at from emergency_resource.medical_resource t
union all select 'expert_force',id,source_code,name,organization_name,contact_phone,availability_status,is_simulated,ST_X(geom),ST_Y(geom),to_jsonb(t)-array['id','source_code','name','organization_name','contact_phone','availability_status','is_simulated','geom','created_at','updated_at'],created_at,updated_at from emergency_resource.expert_force t
union all select 'shelter',id,source_code,name,managing_unit_name,contact_phone,availability_status,is_simulated,ST_X(geom),ST_Y(geom),to_jsonb(t)-array['id','source_code','name','managing_unit_name','contact_phone','availability_status','is_simulated','geom','created_at','updated_at'],created_at,updated_at from emergency_resource.shelter t
union all select 'material_warehouse',id,source_code,name,managing_unit_name,contact_phone,availability_status,is_simulated,ST_X(geom),ST_Y(geom),to_jsonb(t)-array['id','source_code','name','managing_unit_name','contact_phone','availability_status','is_simulated','geom','created_at','updated_at'],created_at,updated_at from emergency_resource.material_warehouse t
union all select 'water_point',id,source_code,name,managing_unit_name,contact_phone,availability_status,is_simulated,ST_X(geom),ST_Y(geom),to_jsonb(t)-array['id','source_code','name','managing_unit_name','contact_phone','availability_status','is_simulated','geom','created_at','updated_at'],created_at,updated_at from emergency_resource.water_point t
union all select 'landing_site',id,source_code,name,managing_unit_name,contact_phone,availability_status,is_simulated,ST_X(geom),ST_Y(geom),to_jsonb(t)-array['id','source_code','name','managing_unit_name','contact_phone','availability_status','is_simulated','geom','created_at','updated_at'],created_at,updated_at from emergency_resource.landing_site t
union all select 'police_station',id,source_code,name,managing_unit_name,contact_phone,availability_status,is_simulated,ST_X(geom),ST_Y(geom),to_jsonb(t)-array['id','source_code','name','managing_unit_name','contact_phone','availability_status','is_simulated','geom','created_at','updated_at'],created_at,updated_at from emergency_resource.police_station t
union all select 'equipment_resource',a.id,a.asset_code,a.name,a.managing_unit_name,null,case when er.active then coalesce(s.dispatch_status,'unknown') else 'inactive' end,a.is_simulated,ST_X(a.geom),ST_Y(a.geom),jsonb_build_object('resource_role',er.resource_role,'active',er.active,'available_from',er.available_from,'available_to',er.available_to,'category_code',a.category_code),er.created_at,er.updated_at from emergency_resource.equipment_resource er join equipment.asset a on a.id=er.asset_id left join equipment.asset_status_current s on s.asset_id=a.id;
comment on view api.emergency_resource_admin_details is '应急资源后台统一只读台账；不包含逐步退出的历史救援队伍。';

create or replace view api.emergency_rescue_forces_history as
select id,source_code,name,force_type,unit_name,commander_name,contact_phone,personnel_count,
availability_status,is_simulated,metadata,ST_X(geom) longitude,ST_Y(geom) latitude,created_at,updated_at
from emergency_resource.rescue_force;
comment on view api.emergency_rescue_forces_history is '逐步退出的历史救援队伍只读资源，不允许新增、修改或删除。';

create or replace view api.emergency_resource_admin_statistics as
select category_code,count(*)::bigint resource_count,count(*) filter(where availability_status in ('available','standby'))::bigint available_count,count(*) filter(where is_simulated)::bigint simulated_count,max(updated_at) last_updated_at
from api.emergency_resource_admin_details group by category_code;
comment on view api.emergency_resource_admin_statistics is '按正式应急资源类别实时统计总数、可用数、模拟数和最后更新时间。';

grant select on api.emergency_resource_admin_details,api.emergency_resource_admin_statistics to admin;
grant select on api.emergency_rescue_forces_history to admin;
revoke insert,update,delete on api.emergency_rescue_forces from admin;
revoke all on api.emergency_resource_admin_details,api.emergency_resource_admin_statistics from public,anonymous;
notify pgrst,'reload schema';
commit;
