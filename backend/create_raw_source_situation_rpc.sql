-- 将 raw schema 中两路无人机和无源雷达数据转换为有界、抽样后的地图校验载荷。
-- 原始表使用无时区时间戳；本接口保持来源时间语义，不推断时区。

begin;

create schema if not exists api;

create index if not exists idx_wyld_batch_send_time
  on raw.eqp_monitor_wyld (batch_no, send_time desc);

drop function if exists api.get_raw_source_situation(
  timestamp without time zone, timestamp without time zone, integer, integer
);

create or replace function api.get_raw_source_situation(
  p_start_at timestamp without time zone,
  p_end_at timestamp without time zone,
  p_drone_sample_seconds integer default 60
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, raw, api
as $$
declare
  v_result jsonb;
begin
  if p_start_at is null or p_end_at is null or p_end_at <= p_start_at then
    raise exception 'p_end_at must be later than p_start_at';
  end if;
  if p_end_at - p_start_at > interval '31 days' then
    raise exception 'raw source situation window cannot exceed 31 days';
  end if;
  if p_drone_sample_seconds < 10 or p_drone_sample_seconds > 86400 then
    raise exception 'p_drone_sample_seconds must be between 10 and 86400';
  end if;
  with source_stats as (
    select 'uav_hf'::text as source_code, '华飞无人机'::text as source_name, 'aircraft_asset'::text as object_kind,
      count(*)::bigint as total_rows,
      count(*) filter (where lon between -180 and 180 and lat between -90 and 90 and not (lon = 0 and lat = 0))::bigint as valid_position_rows,
      count(*) filter (where lon between 73 and 136 and lat between 18 and 54 and not (lon = 0 and lat = 0))::bigint as displayable_rows,
      count(*) filter (where nullif(longitude, '') is null or nullif(latitude, '') is null)::bigint as missing_position_rows,
      count(*) filter (where lon is null or lat is null or lon not between 73 and 136 or lat not between 18 and 54 or (lon = 0 and lat = 0))::bigint as coordinate_anomaly_rows,
      count(*) filter (where altitude_m is not null and (altitude_m < -500 or altitude_m > 10000))::bigint as altitude_anomaly_rows,
      count(*) filter (where speed_mps is not null and (speed_mps < 0 or speed_mps > 100))::bigint as speed_anomaly_rows,
      0::bigint as disappeared_rows, min(observed_at) as first_at, max(observed_at) as last_at
    from (
      select create_time as observed_at,
        case when longitude ~ '^[-+]?[0-9]+([.][0-9]+)?$' then longitude::numeric end as lon,
        case when latitude ~ '^[-+]?[0-9]+([.][0-9]+)?$' then latitude::numeric end as lat,
        case when altitude ~ '^[-+]?[0-9]+([.][0-9]+)?$' then altitude::numeric end as altitude_m,
        case when ground_speed ~ '^[-+]?[0-9]+([.][0-9]+)?$' then ground_speed::numeric end as speed_mps,
        longitude, latitude
      from raw.eqp_wrj_hf
      where create_time >= p_start_at and create_time < p_end_at
    ) hf_base
    union all
    select 'uav_yh', '亿航无人机', 'aircraft_asset', count(*)::bigint,
      count(*) filter (where lon between -180 and 180 and lat between -90 and 90 and not (lon = 0 and lat = 0))::bigint,
      count(*) filter (where lon between 73 and 136 and lat between 18 and 54 and not (lon = 0 and lat = 0))::bigint,
      count(*) filter (where nullif(longitude, '') is null or nullif(latitude, '') is null)::bigint,
      count(*) filter (where lon is null or lat is null or lon not between 73 and 136 or lat not between 18 and 54 or (lon = 0 and lat = 0))::bigint,
      count(*) filter (where altitude_m is not null and (altitude_m < -500 or altitude_m > 10000))::bigint,
      count(*) filter (where speed_mps is not null and (speed_mps < 0 or speed_mps > 100))::bigint,
      0::bigint, min(observed_at), max(observed_at)
    from (
      select create_time as observed_at,
        case when longitude ~ '^[-+]?[0-9]+([.][0-9]+)?$' then longitude::numeric end as lon,
        case when latitude ~ '^[-+]?[0-9]+([.][0-9]+)?$' then latitude::numeric end as lat,
        case when altitude ~ '^[-+]?[0-9]+([.][0-9]+)?$' then altitude::numeric end as altitude_m,
        case when ground_speed ~ '^[-+]?[0-9]+([.][0-9]+)?$' then ground_speed::numeric end as speed_mps,
        longitude, latitude
      from raw.eqp_wrj_yh
      where create_time >= p_start_at and create_time < p_end_at
    ) yh_base
    union all
    select 'passive_radar', '无源雷达', 'airspace_target', count(*)::bigint,
      count(*) filter (where target_lon between -180 and 180 and target_lat between -90 and 90 and not (target_lon = 0 and target_lat = 0))::bigint,
      count(*) filter (where target_lon between 73 and 136 and target_lat between 18 and 54 and not (target_lon = 0 and target_lat = 0))::bigint,
      0::bigint,
      count(*) filter (where target_lon is null or target_lat is null or target_lon not between 73 and 136 or target_lat not between 18 and 54 or (target_lon = 0 and target_lat = 0))::bigint,
      0::bigint,
      count(*) filter (where speed_mps is not null and (speed_mps < 0 or speed_mps > 400))::bigint,
      count(*) filter (where status = 8)::bigint, min(send_time), max(send_time)
    from raw.eqp_monitor_wyld
    where send_time >= p_start_at and send_time < p_end_at
  ),
  drone_candidates as (
    select 'uav_hf'::text as source_code, '华飞无人机'::text as source_name, 'aircraft_asset'::text as object_kind,
      'uav_hf'::text as track_id, observed_at, lon, lat, altitude_m, speed_mps,
      null::numeric as course_degrees, null::integer as status,
      floor(extract(epoch from observed_at) / p_drone_sample_seconds) as sample_bucket
    from (
      select create_time as observed_at, longitude::numeric as lon, latitude::numeric as lat,
        case when altitude ~ '^[-+]?[0-9]+([.][0-9]+)?$' then altitude::numeric end as altitude_m,
        case when ground_speed ~ '^[-+]?[0-9]+([.][0-9]+)?$' then ground_speed::numeric end as speed_mps
      from raw.eqp_wrj_hf
      where create_time >= p_start_at and create_time < p_end_at
        and longitude ~ '^[-+]?[0-9]+([.][0-9]+)?$'
        and latitude ~ '^[-+]?[0-9]+([.][0-9]+)?$'
    ) hf_base where lon between 73 and 136 and lat between 18 and 54 and not (lon = 0 and lat = 0)
    union all
    select 'uav_yh', '亿航无人机', 'aircraft_asset', 'uav_yh', observed_at, lon, lat, altitude_m, speed_mps,
      null::numeric, null::integer,
      floor(extract(epoch from observed_at) / p_drone_sample_seconds)
    from (
      select create_time as observed_at, longitude::numeric as lon, latitude::numeric as lat,
        case when altitude ~ '^[-+]?[0-9]+([.][0-9]+)?$' then altitude::numeric end as altitude_m,
        case when ground_speed ~ '^[-+]?[0-9]+([.][0-9]+)?$' then ground_speed::numeric end as speed_mps
      from raw.eqp_wrj_yh
      where create_time >= p_start_at and create_time < p_end_at
        and longitude ~ '^[-+]?[0-9]+([.][0-9]+)?$'
        and latitude ~ '^[-+]?[0-9]+([.][0-9]+)?$'
    ) yh_base where lon between 73 and 136 and lat between 18 and 54 and not (lon = 0 and lat = 0)
  ),
  sampled_drone as (
    select distinct on (source_code, sample_bucket)
      source_code, source_name, object_kind, track_id, observed_at, lon, lat, altitude_m,
      speed_mps, course_degrees, status
    from drone_candidates
    order by source_code, sample_bucket, observed_at desc
  ),
  sampled_radar as (
    select distinct on (batch_no)
      'passive_radar'::text as source_code, '无源雷达'::text as source_name,
      'airspace_target'::text as object_kind, batch_no::text as track_id,
      send_time as observed_at, target_lon as lon, target_lat as lat,
      null::numeric as altitude_m, speed_mps, course_degrees, status
    from raw.eqp_monitor_wyld
    where send_time >= p_start_at and send_time < p_end_at
      and target_lon between 73 and 136 and target_lat between 18 and 54
      and not (target_lon = 0 and target_lat = 0)
    order by batch_no, send_time desc
  ),
  sampled_points as (
    select * from sampled_drone
    union all
    select * from sampled_radar
  ),
  track_payload as (
    select source_code, source_name, object_kind, track_id,
      jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'observed_at', observed_at, 'lon', lon, 'lat', lat, 'altitude_m', altitude_m,
        'speed_mps', speed_mps, 'course_degrees', course_degrees, 'status', status
      )) order by observed_at) as points
    from sampled_points
    group by source_code, source_name, object_kind, track_id
  ),
  robust_bounds as (
    select
      percentile_cont(0.01) within group (order by lon)::numeric as west,
      percentile_cont(0.01) within group (order by lat)::numeric as south,
      percentile_cont(0.99) within group (order by lon)::numeric as east,
      percentile_cont(0.99) within group (order by lat)::numeric as north
    from sampled_points
  )
  select jsonb_build_object(
    'window', jsonb_build_object(
      'start_at', p_start_at, 'end_at_exclusive', p_end_at,
      'time_semantics', 'source_timestamp_without_timezone',
      'drone_sample_seconds', p_drone_sample_seconds,
      'radar_mode', 'latest_per_track_in_window'
    ),
    'bounds', (select jsonb_build_object('west', west, 'south', south, 'east', east, 'north', north) from robust_bounds),
    'sources', coalesce((select jsonb_agg(to_jsonb(source_stats) order by source_code) from source_stats), '[]'::jsonb),
    'tracks', coalesce((select jsonb_agg(jsonb_build_object(
      'source_code', source_code, 'source_name', source_name, 'object_kind', object_kind,
      'track_id', track_id, 'points', points
    ) order by source_code, track_id) from track_payload), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

comment on function api.get_raw_source_situation(timestamp without time zone, timestamp without time zone, integer) is
'返回 raw 两路无人机与无源雷达在半开时间区间内的地图校验载荷。返回 JSON 格式：window 为来源时间与无人机抽样参数，bounds 为 1%—99% 稳健定位范围，sources 为质量统计，tracks 为按来源和航迹分组的坐标；无人机按时间抽样，雷达每个 batch_no 返回区间内末次位置且高度为空。';

revoke all on function api.get_raw_source_situation(timestamp without time zone, timestamp without time zone, integer) from public;
grant execute on function api.get_raw_source_situation(timestamp without time zone, timestamp without time zone, integer) to admin;

commit;
