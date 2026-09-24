-- Run against a database migrated with backend/create_defense_ring_admin.sql.
-- All fixture writes are rolled back; no production objects are created by this test.
begin;
set local role admin;
do $$
declare
  v_obj jsonb;
  v_saved jsonb;
  v_updated jsonb;
  v_cfg jsonb;
  v_rules jsonb;
  v_failed boolean;
begin
  if has_function_privilege('anonymous','api.save_defense_ring_config(jsonb)','execute') then
    raise exception 'anonymous must not edit defense rings';
  end if;
  if has_table_privilege('admin','airspace.defense_ring','insert') then
    raise exception 'admin must only publish rings through API';
  end if;
  v_obj := jsonb_build_object('name','TEST 防御圈回滚','longitude',119.2683,'latitude',34.6469,
    'enabled',true,'expected_version',0,'radii_m',jsonb_build_array(5000,4000,3000,2000,1000),
    'priorities',jsonb_build_array(100,200,300,400,500));
  v_saved := api.save_defense_ring_config(v_obj);
  v_cfg := api.get_defense_ring_config();
  if (select count(*) from jsonb_array_elements(v_cfg->'objects') o where o->>'name'='TEST 防御圈回滚') <> 1 then
    raise exception 'new protected object missing from read model';
  end if;
  if (select count(*) from jsonb_array_elements(v_cfg->'objects') o,
     jsonb_array_elements(o->'rings') r where o->>'name'='TEST 防御圈回滚') <> 5 then
    raise exception 'five rings not published';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_cfg->'objects') o,
    jsonb_array_elements(o->'rings') r where o->>'name'='TEST 防御圈回滚'
    and r->>'code'='core' and (r->>'radius_m')::numeric=1000) then
    raise exception 'core radius missing';
  end if;
  begin
    perform api.save_defense_ring_config(v_obj || jsonb_build_object('radii_m',jsonb_build_array(1000,4000,3000,2000,1000)));
    raise exception 'invalid nesting accepted';
  exception when others then
    if sqlerrm='invalid nesting accepted' then raise; end if;
  end;
  v_updated := api.save_defense_ring_config(v_obj || jsonb_build_object('id',(v_saved->>'id')::bigint,
    'expected_version',1,'enabled',false,'radii_m',jsonb_build_array(6000,4800,3600,2400,1200)));
  if v_updated->>'version' <> '2' then raise exception 'object revision failed'; end if;
  if (select count(*) from jsonb_array_elements((api.get_defense_ring_config())->'objects') o,
    jsonb_array_elements(o->'rings') r where (o->>'id')::bigint=(v_saved->>'id')::bigint
    and r->>'version'='2') <> 5 then raise exception 'new five-ring version missing'; end if;
  begin
    perform api.save_defense_ring_config(v_obj || jsonb_build_object('id',(v_saved->>'id')::bigint));
    raise exception 'stale version accepted';
  exception when others then
    if sqlerrm='stale version accepted' then raise; end if;
  end;
  v_rules := (api.get_defense_ring_config())->'rules';
  if (v_rules->'factors'->'zone_core'->>'score')::integer <> 85 then raise exception 'missing core score'; end if;
  perform api.save_defense_risk_scores((v_rules->>'version')::integer,
    (select jsonb_object_agg(key,(value->>'score')::integer) from jsonb_each(v_rules->'factors')));
  if ((api.get_defense_ring_config())->'rules'->>'version')::integer <> (v_rules->>'version')::integer+1 then
    raise exception 'score version not published';
  end if;
  begin
    perform api.save_defense_risk_scores((v_rules->>'version')::integer,
      (select jsonb_object_agg(key,(value->>'score')::integer) from jsonb_each(v_rules->'factors')));
    raise exception 'stale rule version accepted';
  exception when others then
    if sqlerrm='stale rule version accepted' then raise; end if;
  end;
end $$;
reset role;
do $$
declare v_object_id bigint;
begin
  select id into v_object_id from airspace.protected_object where name='TEST 防御圈回滚';
  if (select count(*) from airspace.defense_ring where protected_object_id=v_object_id) <> 10 then
    raise exception 'historical rings were not retained';
  end if;
  if not exists (select 1 from airspace.defense_ring r where r.protected_object_id=v_object_id
    and r.code='core' and r.version=1 and r.radius_m=1000
    and st_dwithin(r.center_geom::geography,st_setsrid(st_makepoint(119.2683,34.6469),4326)::geography,r.radius_m)) then
    raise exception 'published center/radius missing';
  end if;
  begin
    update airspace.defense_ring set radius_m=50 where protected_object_id=v_object_id;
    raise exception 'published ring mutation accepted';
  exception when others then
    if sqlerrm='published ring mutation accepted' then raise; end if;
  end;
end $$;
rollback;
