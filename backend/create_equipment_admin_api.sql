-- 设备管理后台 API：设备配置读模型与资产/专业属性原子保存。
-- 依赖 migrate_microwave_radar_model_spec.sql；替代各 profile 的直接 HTTP 写权限。
-- 可安全重复执行。

begin;

create or replace view api.equipment_asset_admin_details as
select
  a.id, a.asset_code, a.category_code, a.type_code, a.name,
  a.source_system, a.source_asset_id, a.managing_unit_name,
  a.deployment_mode, a.lifecycle_status, a.geom,
  ST_X(a.geom) as longitude, ST_Y(a.geom) as latitude,
  a.elevation_amsl_m, a.height_datum, a.manufacturer, a.model,
  a.serial_no, a.is_simulated, a.metadata, a.created_at, a.updated_at
from equipment.asset a;

comment on view api.equipment_asset_admin_details is '设备管理后台使用的资产详情只读资源，额外提供经纬度字段。';
comment on column api.equipment_asset_admin_details.longitude is '资产登记位置经度，WGS84 十进制度。';
comment on column api.equipment_asset_admin_details.latitude is '资产登记位置纬度，WGS84 十进制度。';

create or replace view api.equipment_capability_catalog as
select code, name, capability_type, description
from equipment.capability;
comment on view api.equipment_capability_catalog is '设备管理后台使用的能力字典只读资源。';

create or replace function equipment.profile_table_for_category(p_category_code text)
returns text
language sql
immutable
strict
as $$
select case p_category_code
  when 'base_station_6g' then 'base_station_6g_profile'
  when 'counter_uas' then 'counter_uas_profile'
  when 'video_surveillance' then 'video_surveillance_profile'
  when 'uav' then 'uav_profile'
  when 'unmanned_vehicle' then 'unmanned_vehicle_profile'
  when 'vehicle_surveillance' then 'vehicle_surveillance_profile'
  when 'sensor' then 'sensor_profile'
  when 'jamming_device' then 'jamming_device_profile'
  when 'aoa_direction_finder' then 'aoa_direction_finder_profile'
  when 'microwave_radar' then 'microwave_radar_profile'
  when 'remote_id_receiver' then 'remote_id_receiver_profile'
  when 'directed_energy_device' then 'directed_energy_device_profile'
  when 'electro_optical_device' then 'electro_optical_device_profile'
end
$$;
comment on function equipment.profile_table_for_category(text) is '返回设备类别对应的专业属性表名，未知类别返回空值。';

create or replace function api.get_equipment_configuration(p_asset_id bigint)
returns jsonb
language plpgsql
stable
set search_path = api, equipment, public, pg_temp
as $$
declare
  v_asset equipment.asset%rowtype;
  v_profile_table text;
  v_profile jsonb;
  v_capabilities jsonb;
  v_sensor_channels jsonb;
  v_dispatch_resource jsonb;
  v_coverages jsonb;
begin
  select * into v_asset from equipment.asset where id = p_asset_id;
  if not found then
    raise exception 'equipment asset % does not exist', p_asset_id;
  end if;

  v_profile_table := equipment.profile_table_for_category(v_asset.category_code);
  if v_profile_table is null then
    raise exception 'unsupported equipment category %', v_asset.category_code;
  end if;

  execute format(
    'select to_jsonb(p) - ''asset_id'' from equipment.%I p where p.asset_id = $1',
    v_profile_table
  ) into v_profile using p_asset_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', ac.id,
    'capability_code', ac.capability_code,
    'capability_name', c.name,
    'capability_type', c.capability_type,
    'access_level', ac.access_level,
    'enabled', ac.enabled,
    'parameters', ac.parameters
  ) order by ac.id), '[]'::jsonb)
  into v_capabilities
  from equipment.asset_capability ac
  join equipment.capability c on c.code = ac.capability_code
  where ac.asset_id = p_asset_id;

  if v_asset.category_code = 'sensor' then
    select coalesce(jsonb_agg(to_jsonb(sc) - 'asset_id' order by sc.id), '[]'::jsonb)
    into v_sensor_channels
    from equipment.sensor_channel sc
    where sc.asset_id = p_asset_id;
  else
    v_sensor_channels := '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', cov.id,
    'capability_code', ac.capability_code,
    'coverage_geom', ST_AsGeoJSON(cov.coverage_geom)::jsonb,
    'min_height_amsl_m', cov.min_height_amsl_m,
    'max_height_amsl_m', cov.max_height_amsl_m,
    'height_datum', cov.height_datum,
    'valid_from', cov.valid_from,
    'valid_to', cov.valid_to,
    'metadata', cov.metadata
  ) order by cov.id), '[]'::jsonb)
  into v_coverages
  from equipment.asset_coverage cov
  join equipment.asset_capability ac on ac.id = cov.asset_capability_id
  where ac.asset_id = p_asset_id;

  select to_jsonb(er) - 'asset_id'
  into v_dispatch_resource
  from emergency_resource.equipment_resource er
  where er.asset_id = p_asset_id;

  return jsonb_build_object(
    'asset', to_jsonb(v_asset) - 'geom' || jsonb_build_object(
      'longitude', ST_X(v_asset.geom),
      'latitude', ST_Y(v_asset.geom)
    ),
    'profile', coalesce(v_profile, '{}'::jsonb),
    'capabilities', v_capabilities,
    'sensor_channels', v_sensor_channels,
    'dispatch_resource', v_dispatch_resource,
    'coverages', v_coverages
  );
end;
$$;
comment on function api.get_equipment_configuration(bigint) is '返回单个设备的资产、专业属性、能力、传感通道和调度资源配置 JSON。';

create or replace function equipment.validate_capability_parameters(p_capability_code text,p_parameters jsonb)
returns void
language plpgsql
stable
set search_path = equipment, public, pg_temp
as $$
declare
  v_min_range numeric;
  v_max_range numeric;
  v_min_frequency numeric;
  v_max_frequency numeric;
  v_key text;
begin
  if p_parameters is null or jsonb_typeof(p_parameters) <> 'object' then
    raise exception 'capability % parameters must be a JSON object',p_capability_code;
  end if;
  foreach v_key in array array['min_range_m','max_range_m','frequency_min_mhz','frequency_max_mhz']
  loop
    if p_parameters ? v_key and jsonb_typeof(p_parameters->v_key) not in ('number','null') then
      raise exception 'capability % parameter % must be numeric or null',p_capability_code,v_key;
    end if;
  end loop;
  v_min_range:=nullif(p_parameters->>'min_range_m','')::numeric;
  v_max_range:=nullif(p_parameters->>'max_range_m','')::numeric;
  v_min_frequency:=nullif(p_parameters->>'frequency_min_mhz','')::numeric;
  v_max_frequency:=nullif(p_parameters->>'frequency_max_mhz','')::numeric;
  if v_min_range is not null and v_min_range<0 then raise exception 'capability minimum range cannot be negative'; end if;
  if v_max_range is not null and v_max_range<=0 then raise exception 'capability maximum range must be positive'; end if;
  if v_min_range is not null and v_max_range is not null and v_min_range>v_max_range then
    raise exception 'capability minimum range cannot exceed maximum range';
  end if;
  if v_min_frequency is not null and v_min_frequency<0 then raise exception 'capability minimum frequency cannot be negative'; end if;
  if v_max_frequency is not null and v_max_frequency<0 then raise exception 'capability maximum frequency cannot be negative'; end if;
  if v_min_frequency is not null and v_max_frequency is not null and v_min_frequency>v_max_frequency then
    raise exception 'capability minimum frequency cannot exceed maximum frequency';
  end if;
  if p_parameters ? 'range_basis' and coalesce(p_parameters->>'range_basis','') not in ('vendor_spec','measured','estimated','manual') then
    raise exception 'capability range_basis is invalid';
  end if;
end;
$$;
comment on function equipment.validate_capability_parameters(text,jsonb) is '校验设备能力距离、频率和参数依据；校验成功无返回值。';

create or replace function api.save_equipment_configuration(
  p_asset jsonb,
  p_profile jsonb,
  p_expected_updated_at timestamptz default null
)
returns jsonb
language plpgsql
set search_path = api, equipment, public, pg_temp
as $$
declare
  v_asset_id bigint;
  v_category_code text;
  v_existing_category text;
  v_current_updated_at timestamptz;
  v_saved_updated_at timestamptz;
  v_longitude double precision;
  v_latitude double precision;
  v_geom geometry(Point, 4326);
  v_profile_table text;
  v_profile_payload jsonb;
  v_columns text;
  v_values text;
  v_unknown_field text;
  v_profile_exists boolean;
  v_related_item jsonb;
  v_asset_capability_id bigint;
  v_coverage_geom geometry(MultiPolygon, 4326);
  v_capability_parameters jsonb;
  v_coverage_metadata jsonb;
begin
  if p_asset is null or jsonb_typeof(p_asset) <> 'object' then
    raise exception 'asset configuration must be a JSON object';
  end if;
  if p_profile is null or jsonb_typeof(p_profile) <> 'object' then
    raise exception 'equipment profile configuration must be a JSON object';
  end if;

  v_category_code := nullif(p_asset->>'category_code', '');
  if v_category_code is null then
    raise exception 'category_code is required';
  end if;
  v_profile_table := equipment.profile_table_for_category(v_category_code);
  if v_profile_table is null then
    raise exception 'unsupported equipment category %', v_category_code;
  end if;
  if not exists (
    select 1 from equipment.asset_category
    where code = v_category_code and enabled
  ) then
    raise exception 'equipment category % is disabled or unknown', v_category_code;
  end if;
  if nullif(p_asset->>'asset_code', '') is null or nullif(p_asset->>'name', '') is null then
    raise exception 'asset_code and name are required';
  end if;
  if v_category_code = 'microwave_radar' and nullif(p_profile->>'model_code', '') is null then
    raise exception 'radar model_code is required';
  end if;

  begin
    v_longitude := (p_asset->>'longitude')::double precision;
    v_latitude := (p_asset->>'latitude')::double precision;
  exception when invalid_text_representation or numeric_value_out_of_range then
    raise exception 'longitude and latitude must be valid numbers';
  end;
  if v_longitude is null or v_longitude < -180 or v_longitude > 180
     or v_latitude is null or v_latitude < -90 or v_latitude > 90 then
    raise exception 'longitude or latitude is outside the WGS84 range';
  end if;
  v_geom := ST_SetSRID(ST_MakePoint(v_longitude, v_latitude), 4326);

  if p_asset ? 'id' and nullif(p_asset->>'id', '') is not null then
    v_asset_id := (p_asset->>'id')::bigint;
    select category_code, updated_at
      into v_existing_category, v_current_updated_at
    from equipment.asset where id = v_asset_id for update;
    if not found then
      raise exception 'equipment asset % does not exist', v_asset_id;
    end if;
    if v_existing_category <> v_category_code then
      raise exception 'equipment category is immutable; expected %, got %', v_existing_category, v_category_code;
    end if;
    if p_expected_updated_at is not null and v_current_updated_at <> p_expected_updated_at then
      raise exception 'equipment configuration has been modified; reload before saving';
    end if;

    update equipment.asset set
      name = p_asset->>'name',
      type_code = nullif(p_asset->>'type_code', ''),
      managing_unit_name = nullif(p_asset->>'managing_unit_name', ''),
      deployment_mode = nullif(p_asset->>'deployment_mode', ''),
      geom = v_geom,
      elevation_amsl_m = nullif(p_asset->>'elevation_amsl_m', '')::numeric,
      manufacturer = nullif(p_asset->>'manufacturer', ''),
      model = case when v_category_code = 'microwave_radar'
                   then p_profile->>'model_code' else nullif(p_asset->>'model', '') end,
      serial_no = nullif(p_asset->>'serial_no', '')
    where id = v_asset_id;
  else
    insert into equipment.asset(
      asset_code, category_code, type_code, name, source_system, source_asset_id,
      managing_unit_name, deployment_mode, lifecycle_status, geom,
      elevation_amsl_m, height_datum, manufacturer, model, serial_no,
      is_simulated, metadata
    ) values (
      p_asset->>'asset_code', v_category_code, nullif(p_asset->>'type_code', ''), p_asset->>'name',
      coalesce(nullif(p_asset->>'source_system', ''), 'admin_console'),
      coalesce(nullif(p_asset->>'source_asset_id', ''), p_asset->>'asset_code'),
      nullif(p_asset->>'managing_unit_name', ''), nullif(p_asset->>'deployment_mode', ''),
      'active', v_geom, nullif(p_asset->>'elevation_amsl_m', '')::numeric, 'AMSL',
      nullif(p_asset->>'manufacturer', ''),
      case when v_category_code = 'microwave_radar'
           then p_profile->>'model_code' else nullif(p_asset->>'model', '') end,
      nullif(p_asset->>'serial_no', ''),
      coalesce((p_asset->>'is_simulated')::boolean, false),
      coalesce(p_asset->'metadata', '{}'::jsonb)
    ) returning id into v_asset_id;
  end if;

  -- asset_id 由函数决定，调用方不能通过 profile 覆盖。
  v_profile_payload := p_profile - 'asset_id';
  select key into v_unknown_field
  from jsonb_object_keys(v_profile_payload) as key
  where not exists (
    select 1 from pg_attribute
    where attrelid = format('equipment.%I', v_profile_table)::regclass
      and attname = key and attnum > 0 and not attisdropped
  )
  limit 1;
  if v_unknown_field is not null then
    raise exception 'unknown profile field % for category %', v_unknown_field, v_category_code;
  end if;

  select
    string_agg(format('%I', a.attname), ', ' order by a.attnum),
    string_agg(
      format('(jsonb_populate_record(null::equipment.%I, $1)).%I', v_profile_table, a.attname),
      ', ' order by a.attnum
    )
  into v_columns, v_values
  from pg_attribute a
  where a.attrelid = format('equipment.%I', v_profile_table)::regclass
    and a.attnum > 0 and not a.attisdropped and a.attname <> 'asset_id'
    and v_profile_payload ? a.attname;

  execute format('select exists(select 1 from equipment.%I where asset_id = $1)', v_profile_table)
    into v_profile_exists using v_asset_id;
  if v_profile_exists then
    if v_columns is not null then
      execute format(
        'update equipment.%I set (%s) = (select %s) where asset_id = $2',
        v_profile_table, v_columns, v_values
      ) using v_profile_payload, v_asset_id;
    end if;
  else
    if v_columns is null then
      execute format('insert into equipment.%I(asset_id) values ($1)', v_profile_table)
      using v_asset_id;
    else
      execute format(
        'insert into equipment.%I(asset_id, %s) select $2, %s',
        v_profile_table, v_columns, v_values
      ) using v_profile_payload, v_asset_id;
    end if;
  end if;

  if p_asset ? 'capabilities' then
    if jsonb_typeof(p_asset->'capabilities') <> 'array' then
      raise exception 'capabilities must be a JSON array';
    end if;
    delete from equipment.asset_capability ac
    where ac.asset_id = v_asset_id
      and not exists (
        select 1 from jsonb_array_elements(p_asset->'capabilities') item
        where item->>'capability_code' = ac.capability_code
      );
    for v_related_item in select value from jsonb_array_elements(p_asset->'capabilities')
    loop
      if nullif(v_related_item->>'capability_code', '') is null then
        raise exception 'capability_code is required';
      end if;
      v_capability_parameters:=coalesce(v_related_item->'parameters','{}'::jsonb);
      perform equipment.validate_capability_parameters(v_related_item->>'capability_code',v_capability_parameters);
      insert into equipment.asset_capability(
        asset_id, capability_code, access_level, enabled, parameters
      ) values (
        v_asset_id,
        v_related_item->>'capability_code',
        coalesce(nullif(v_related_item->>'access_level', ''), 'observable'),
        coalesce((v_related_item->>'enabled')::boolean, true),
        v_capability_parameters
      )
      on conflict (asset_id, capability_code) do update set
        access_level = excluded.access_level,
        enabled = excluded.enabled,
        parameters = excluded.parameters;
    end loop;
  end if;

  if p_asset ? 'coverages' then
    if jsonb_typeof(p_asset->'coverages') <> 'array' then
      raise exception 'coverages must be a JSON array';
    end if;
    delete from equipment.asset_coverage cov
    using equipment.asset_capability ac
    where cov.asset_capability_id = ac.id and ac.asset_id = v_asset_id
      and not exists (
        select 1 from jsonb_array_elements(p_asset->'coverages') item
        where nullif(item->>'id', '')::bigint = cov.id
      );
    for v_related_item in select value from jsonb_array_elements(p_asset->'coverages')
    loop
      select id,parameters into v_asset_capability_id,v_capability_parameters
      from equipment.asset_capability
      where asset_id = v_asset_id and capability_code = v_related_item->>'capability_code';
      if v_asset_capability_id is null then
        raise exception 'coverage capability % is not assigned to asset', v_related_item->>'capability_code';
      end if;
      begin
        v_coverage_geom := ST_Multi(ST_SetSRID(ST_GeomFromGeoJSON(v_related_item->'coverage_geom'), 4326));
      exception when others then
        raise exception 'coverage_geom must be valid Polygon or MultiPolygon GeoJSON';
      end;
      if GeometryType(v_coverage_geom) <> 'MULTIPOLYGON' then
        raise exception 'coverage_geom must be Polygon or MultiPolygon GeoJSON';
      end if;
      if ST_IsEmpty(v_coverage_geom) then
        raise exception 'coverage_geom cannot be empty';
      end if;
      if not ST_IsValid(v_coverage_geom) then
        raise exception 'coverage_geom is invalid: %', ST_IsValidReason(v_coverage_geom);
      end if;

      v_coverage_metadata:=coalesce(v_related_item->'metadata','{}'::jsonb);
      if jsonb_typeof(v_coverage_metadata)<>'object' then raise exception 'coverage metadata must be a JSON object'; end if;
      if v_coverage_metadata ? 'coverage_model'
         and v_coverage_metadata->>'coverage_model' not in ('manual','radial','sector') then
        raise exception 'coverage_model must be manual, radial or sector';
      end if;
      if v_coverage_metadata->>'coverage_model' in ('radial','sector') then
        if jsonb_typeof(v_coverage_metadata->'radius_m') is distinct from 'number'
           or (v_coverage_metadata->>'radius_m')::numeric <= 0 then
          raise exception 'generated coverage radius_m must be positive';
        end if;
        if nullif(v_capability_parameters->>'max_range_m','') is not null
           and (v_coverage_metadata->>'radius_m')::numeric>(v_capability_parameters->>'max_range_m')::numeric then
          raise exception 'generated coverage radius_m cannot exceed capability maximum range';
        end if;
        if coalesce((v_coverage_metadata->>'generated_from_asset_position')::boolean,false)
           and not ST_Covers(v_coverage_geom,v_geom) then
          raise exception 'coverage generated from asset position must cover the asset location';
        end if;
      end if;
      if v_coverage_metadata->>'coverage_model'='sector' then
        if jsonb_typeof(v_coverage_metadata->'azimuth_start_deg') is distinct from 'number'
           or jsonb_typeof(v_coverage_metadata->'azimuth_end_deg') is distinct from 'number'
           or (v_coverage_metadata->>'azimuth_start_deg')::numeric not between 0 and 360
           or (v_coverage_metadata->>'azimuth_end_deg')::numeric not between 0 and 360
           or (v_coverage_metadata->>'azimuth_start_deg')::numeric=(v_coverage_metadata->>'azimuth_end_deg')::numeric then
          raise exception 'sector coverage azimuths must be distinct numbers between 0 and 360';
        end if;
      end if;

      if nullif(v_related_item->>'id', '') is null then
        insert into equipment.asset_coverage(
          asset_capability_id, coverage_geom, min_height_amsl_m, max_height_amsl_m,
          height_datum, valid_from, valid_to, metadata
        ) values (
          v_asset_capability_id, v_coverage_geom,
          nullif(v_related_item->>'min_height_amsl_m', '')::numeric,
          nullif(v_related_item->>'max_height_amsl_m', '')::numeric, 'AMSL',
          nullif(v_related_item->>'valid_from', '')::timestamptz,
          nullif(v_related_item->>'valid_to', '')::timestamptz,
          v_coverage_metadata
        );
      else
        update equipment.asset_coverage cov set
          asset_capability_id = v_asset_capability_id,
          coverage_geom = v_coverage_geom,
          min_height_amsl_m = nullif(v_related_item->>'min_height_amsl_m', '')::numeric,
          max_height_amsl_m = nullif(v_related_item->>'max_height_amsl_m', '')::numeric,
          valid_from = nullif(v_related_item->>'valid_from', '')::timestamptz,
          valid_to = nullif(v_related_item->>'valid_to', '')::timestamptz,
          metadata = v_coverage_metadata
        from equipment.asset_capability ac
        where cov.id = (v_related_item->>'id')::bigint
          and cov.asset_capability_id = ac.id and ac.asset_id = v_asset_id;
        if not found then raise exception 'coverage % does not belong to asset', v_related_item->>'id'; end if;
      end if;
    end loop;
  end if;

  if p_asset ? 'sensor_channels' then
    if v_category_code <> 'sensor' then
      raise exception 'sensor_channels are only valid for sensor assets';
    end if;
    if jsonb_typeof(p_asset->'sensor_channels') <> 'array' then
      raise exception 'sensor_channels must be a JSON array';
    end if;
    delete from equipment.sensor_channel where asset_id = v_asset_id;
    for v_related_item in select value from jsonb_array_elements(p_asset->'sensor_channels')
    loop
      insert into equipment.sensor_channel(
        asset_id, channel_code, metric_code, unit, warning_threshold
      ) values (
        v_asset_id,
        v_related_item->>'channel_code',
        v_related_item->>'metric_code',
        nullif(v_related_item->>'unit', ''),
        coalesce(v_related_item->'warning_threshold', '{}'::jsonb)
      );
    end loop;
  end if;

  if p_asset ? 'dispatch_resource' then
    if p_asset->'dispatch_resource' = 'null'::jsonb then
      delete from emergency_resource.equipment_resource where asset_id = v_asset_id;
    else
      v_related_item := p_asset->'dispatch_resource';
      insert into emergency_resource.equipment_resource(
        asset_id, resource_role, active, available_from, available_to, metadata
      ) values (
        v_asset_id,
        v_related_item->>'resource_role',
        coalesce((v_related_item->>'active')::boolean, true),
        nullif(v_related_item->>'available_from', '')::timestamptz,
        nullif(v_related_item->>'available_to', '')::timestamptz,
        coalesce(v_related_item->'metadata', '{}'::jsonb)
      )
      on conflict (asset_id) do update set
        resource_role = excluded.resource_role,
        active = excluded.active,
        available_from = excluded.available_from,
        available_to = excluded.available_to,
        metadata = excluded.metadata;
    end if;
  end if;

  select updated_at into v_saved_updated_at from equipment.asset where id = v_asset_id;
  return jsonb_build_object('asset_id', v_asset_id, 'updated_at', v_saved_updated_at);
end;
$$;
comment on function api.save_equipment_configuration(jsonb, jsonb, timestamptz) is '在单个事务中保存设备资产、专业属性、能力、传感通道和调度资源，返回 asset_id 与 updated_at。';

create or replace function api.update_equipment_category(p_code text, p_changes jsonb)
returns void language plpgsql set search_path = api, equipment, public, pg_temp as $$
begin
  update equipment.asset_category set
    name=coalesce(nullif(p_changes->>'name',''),name),
    category_group=coalesce(nullif(p_changes->>'category_group',''),category_group),
    description=case when p_changes?'description' then nullif(p_changes->>'description','') else description end,
    enabled=case when p_changes?'enabled' then (p_changes->>'enabled')::boolean else enabled end,
    sort_order=case when p_changes?'sort_order' then (p_changes->>'sort_order')::integer else sort_order end
  where code=p_code;
  if not found then raise exception 'equipment category % does not exist',p_code; end if;
end $$;
comment on function api.update_equipment_category(text,jsonb) is '按编码更新设备类别的名称、分组、说明、启用状态和排序，不允许修改编码。';

create or replace function api.update_equipment_capability(p_code text, p_changes jsonb)
returns void language plpgsql set search_path = api, equipment, public, pg_temp as $$
begin
  update equipment.capability set
    name=coalesce(nullif(p_changes->>'name',''),name),
    capability_type=coalesce(nullif(p_changes->>'capability_type',''),capability_type),
    description=case when p_changes?'description' then nullif(p_changes->>'description','') else description end
  where code=p_code;
  if not found then raise exception 'equipment capability % does not exist',p_code; end if;
end $$;
comment on function api.update_equipment_capability(text,jsonb) is '按编码更新设备能力的名称、类型和说明，不允许修改编码。';

create or replace function api.update_equipment_radar_model(p_model_code text, p_changes jsonb)
returns void language plpgsql set search_path = api, equipment, public, pg_temp as $$
begin
  update equipment.device_model set
    name=coalesce(nullif(p_changes->>'name',''),name),
    manufacturer=case when p_changes?'manufacturer' then nullif(p_changes->>'manufacturer','') else manufacturer end
  where model_code=p_model_code and category_code='microwave_radar';
  if not found then raise exception 'radar model % does not exist',p_model_code; end if;
  update equipment.radar_model_spec set
    work_system=coalesce(nullif(p_changes->>'work_system',''),work_system),
    frequency_band=coalesce(nullif(p_changes->>'frequency_band',''),frequency_band),
    range_search_m=case when p_changes?'range_search_m' then (p_changes->>'range_search_m')::integer else range_search_m end,
    range_phase_search_m=case when p_changes?'range_phase_search_m' then nullif(p_changes->>'range_phase_search_m','')::integer else range_phase_search_m end,
    coverage_height_m=case when p_changes?'coverage_height_m' then (p_changes->>'coverage_height_m')::integer else coverage_height_m end,
    capacity_search=case when p_changes?'capacity_search' then (p_changes->>'capacity_search')::integer else capacity_search end,
    capacity_track=case when p_changes?'capacity_track' then (p_changes->>'capacity_track')::integer else capacity_track end,
    power_w=case when p_changes?'power_w' then nullif(p_changes->>'power_w','')::numeric else power_w end
  where model_code=p_model_code;
end $$;
comment on function api.update_equipment_radar_model(text,jsonb) is '按型号编码更新雷达型号名称、厂商和常用静态规格，不允许修改型号编码。';

-- 保留既有雷达 RPC 路径，内部统一转发到通用事务保存函数。
create or replace function api.save_microwave_radar_configuration(
  p_asset jsonb,
  p_profile jsonb,
  p_expected_updated_at timestamptz default null
)
returns jsonb
language sql
set search_path = api, equipment, public, pg_temp
as $$
select api.save_equipment_configuration(
  p_asset || jsonb_build_object('category_code', 'microwave_radar'),
  p_profile,
  p_expected_updated_at
)
$$;
comment on function api.save_microwave_radar_configuration(jsonb, jsonb, timestamptz) is '兼容雷达管理页面的事务保存接口，返回 asset_id 与 updated_at。';

revoke all on function equipment.profile_table_for_category(text) from public, anonymous;
revoke all on function equipment.validate_capability_parameters(text,jsonb) from public, anonymous;
grant execute on function equipment.profile_table_for_category(text) to admin;
grant execute on function equipment.validate_capability_parameters(text,jsonb) to admin;
revoke all on function api.get_equipment_configuration(bigint) from public, anonymous;
revoke all on function api.save_equipment_configuration(jsonb, jsonb, timestamptz) from public, anonymous;
revoke all on function api.save_microwave_radar_configuration(jsonb, jsonb, timestamptz) from public, anonymous;
revoke all on function api.update_equipment_category(text, jsonb) from public, anonymous;
revoke all on function api.update_equipment_capability(text, jsonb) from public, anonymous;
revoke all on function api.update_equipment_radar_model(text, jsonb) from public, anonymous;
grant execute on function api.get_equipment_configuration(bigint) to admin;
grant execute on function api.save_equipment_configuration(jsonb, jsonb, timestamptz) to admin;
grant execute on function api.save_microwave_radar_configuration(jsonb, jsonb, timestamptz) to admin;
grant execute on function api.update_equipment_category(text, jsonb) to admin;
grant execute on function api.update_equipment_capability(text, jsonb) to admin;
grant execute on function api.update_equipment_radar_model(text, jsonb) to admin;
grant select on api.equipment_asset_admin_details to admin;
grant select on api.equipment_capability_catalog to admin;

-- 所有专业属性均通过事务 RPC 写入，HTTP 视图保持只读。
revoke insert, update, delete on api.equipment_microwave_radar_profiles from admin;

notify pgrst, 'reload schema';
commit;
