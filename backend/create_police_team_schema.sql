-- 警员、警务编组及警务站挂载关系。
--
-- 前置条件：先执行 backend/create_police_station_schema.sql。
-- 警员可以兼任多个编组；组长也是编组成员，通过 member_role='leader' 表达。
-- 成员离组时填写 left_at，不删除历史记录。

begin;

create schema if not exists emergency_resource;
create schema if not exists api;

create or replace function emergency_resource.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function emergency_resource.touch_updated_at() is '维护应急资源业务表的 updated_at 字段。';

-- -----------------------------------------------------------------------------
-- 警员
-- -----------------------------------------------------------------------------
create table if not exists emergency_resource.police_officer (
  id bigserial primary key,
  officer_no text not null unique check (btrim(officer_no) <> ''),
  name text not null check (btrim(name) <> ''),
  contact_phone text,
  organization_name text,
  availability_status text not null default 'available'
    check (availability_status in ('available', 'on_duty', 'dispatched', 'leave', 'unavailable')),
  is_active boolean not null default true,
  is_simulated boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table emergency_resource.police_officer is '可参与警务编组和事件处置调度的警员档案；与平台登录账号相互独立。';
-- 兼容已部署的首版表结构。
alter table emergency_resource.police_officer
  add column if not exists is_simulated boolean not null default false;

comment on column emergency_resource.police_officer.officer_no is '警号，作为警员业务唯一标识。';
comment on column emergency_resource.police_officer.name is '警员姓名。';
comment on column emergency_resource.police_officer.contact_phone is '警员工作联系方式，属于敏感信息，仅向已认证管理角色开放。';
comment on column emergency_resource.police_officer.organization_name is '警员所属公安机关或业务单位名称。';
comment on column emergency_resource.police_officer.availability_status is '警员状态：available 可用、on_duty 值勤、dispatched 已出动、leave 请假、unavailable 不可用。';
comment on column emergency_resource.police_officer.is_active is '警员档案是否有效；离职或停用后设为 false，不删除历史成员关系。';
comment on column emergency_resource.police_officer.is_simulated is '是否为模拟警员数据；用于后台明确区分演示数据和真实数据。';
comment on column emergency_resource.police_officer.metadata is '来源标识及其他非核心扩展属性。';

create index if not exists police_officer_name_idx
  on emergency_resource.police_officer (name);
create index if not exists police_officer_availability_status_idx
  on emergency_resource.police_officer (availability_status);

-- -----------------------------------------------------------------------------
-- 警务编组
-- -----------------------------------------------------------------------------
create table if not exists emergency_resource.police_team (
  id bigserial primary key,
  team_code text not null unique check (btrim(team_code) <> ''),
  name text not null check (btrim(name) <> ''),
  station_id bigint references emergency_resource.police_station(id)
    on update cascade on delete set null,
  team_status text not null default 'active'
    check (team_status in ('active', 'standby', 'dispatched', 'inactive')),
  description text,
  is_simulated boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table emergency_resource.police_team is '由一名组长和若干成员组成、可挂载到一个警务站的警务编组。';
-- 兼容已部署的首版表结构。
alter table emergency_resource.police_team
  add column if not exists is_simulated boolean not null default false;

comment on column emergency_resource.police_team.team_code is '警务编组稳定且唯一的业务编码。';
comment on column emergency_resource.police_team.name is '警务编组名称。';
comment on column emergency_resource.police_team.station_id is '当前挂载的警务站；为空表示暂未挂载，一个警务站可以挂载多个编组。';
comment on column emergency_resource.police_team.team_status is '编组状态：active 正常、standby 待命、dispatched 已出动、inactive 停用。';
comment on column emergency_resource.police_team.is_simulated is '是否为模拟编组数据；用于后台明确区分演示数据和真实数据。';
comment on column emergency_resource.police_team.metadata is '编组来源及其他非核心扩展属性。';

create index if not exists police_team_station_id_idx
  on emergency_resource.police_team (station_id);
create index if not exists police_team_status_idx
  on emergency_resource.police_team (team_status);

-- -----------------------------------------------------------------------------
-- 编组成员及任职历史
-- -----------------------------------------------------------------------------
create table if not exists emergency_resource.police_team_member (
  id bigserial primary key,
  team_id bigint not null references emergency_resource.police_team(id)
    on update cascade on delete cascade,
  officer_id bigint not null references emergency_resource.police_officer(id)
    on update cascade on delete restrict,
  member_role text not null default 'member'
    check (member_role in ('leader', 'deputy_leader', 'member')),
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (left_at is null or left_at >= joined_at)
);

comment on table emergency_resource.police_team_member is '警员参加警务编组的成员关系及任职历史；组长也是 member_role=leader 的成员。';
comment on column emergency_resource.police_team_member.team_id is '成员所属警务编组。';
comment on column emergency_resource.police_team_member.officer_id is '参加编组的警员。';
comment on column emergency_resource.police_team_member.member_role is '成员角色：leader 组长、deputy_leader 副组长、member 普通成员。';
comment on column emergency_resource.police_team_member.joined_at is '加入编组的时间。';
comment on column emergency_resource.police_team_member.left_at is '离开编组的时间；为空表示当前仍在该编组。';

create unique index if not exists police_team_one_active_leader_uq
  on emergency_resource.police_team_member (team_id)
  where member_role = 'leader' and left_at is null;

create unique index if not exists police_team_one_active_membership_uq
  on emergency_resource.police_team_member (team_id, officer_id)
  where left_at is null;

create index if not exists police_team_member_officer_id_idx
  on emergency_resource.police_team_member (officer_id);

-- 三张业务表统一维护更新时间。
drop trigger if exists police_officer_touch_updated_at on emergency_resource.police_officer;
create trigger police_officer_touch_updated_at
before update on emergency_resource.police_officer
for each row execute function emergency_resource.touch_updated_at();

drop trigger if exists police_team_touch_updated_at on emergency_resource.police_team;
create trigger police_team_touch_updated_at
before update on emergency_resource.police_team
for each row execute function emergency_resource.touch_updated_at();

drop trigger if exists police_team_member_touch_updated_at on emergency_resource.police_team_member;
create trigger police_team_member_touch_updated_at
before update on emergency_resource.police_team_member
for each row execute function emergency_resource.touch_updated_at();

-- 原子更换组长，避免先撤销旧组长后再设置新组长造成中间状态或唯一约束冲突。
create or replace function emergency_resource.assign_police_team_leader(
  p_team_id bigint,
  p_officer_id bigint
)
returns emergency_resource.police_team_member
language plpgsql
set search_path = emergency_resource, public, pg_temp
as $$
declare
  v_membership emergency_resource.police_team_member%rowtype;
begin
  perform 1
  from emergency_resource.police_team
  where id = p_team_id
  for update;
  if not found then
    raise exception 'police team % does not exist', p_team_id
      using errcode = '23503';
  end if;

  perform 1
  from emergency_resource.police_officer
  where id = p_officer_id and is_active;
  if not found then
    raise exception 'active police officer % does not exist', p_officer_id
      using errcode = '23503';
  end if;

  update emergency_resource.police_team_member
  set member_role = 'member'
  where team_id = p_team_id
    and member_role = 'leader'
    and left_at is null
    and officer_id <> p_officer_id;

  update emergency_resource.police_team_member
  set member_role = 'leader'
  where team_id = p_team_id
    and officer_id = p_officer_id
    and left_at is null
  returning * into v_membership;

  if not found then
    insert into emergency_resource.police_team_member (
      team_id, officer_id, member_role
    ) values (
      p_team_id, p_officer_id, 'leader'
    )
    returning * into v_membership;
  end if;

  return v_membership;
end;
$$;

comment on function emergency_resource.assign_police_team_leader(bigint, bigint) is '原子设置或更换编组组长；返回该组长当前的 police_team_member 单条记录。';

-- 原子创建编组并建立组长成员关系，避免后台产生没有组长的半完成记录。
create or replace function emergency_resource.create_police_team(
  p_team_code text,
  p_name text,
  p_leader_officer_id bigint,
  p_station_id bigint default null,
  p_team_status text default 'active',
  p_description text default null,
  p_is_simulated boolean default false,
  p_metadata jsonb default '{}'::jsonb
)
returns emergency_resource.police_team
language plpgsql
set search_path = emergency_resource, public, pg_temp
as $$
declare
  v_team emergency_resource.police_team%rowtype;
begin
  insert into emergency_resource.police_team (
    team_code, name, station_id, team_status, description, is_simulated, metadata
  ) values (
    p_team_code, p_name, p_station_id, p_team_status, p_description,
    coalesce(p_is_simulated, false), coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into v_team;

  perform emergency_resource.assign_police_team_leader(v_team.id, p_leader_officer_id);
  return v_team;
end;
$$;

comment on function emergency_resource.create_police_team(text, text, bigint, bigint, text, text, boolean, jsonb) is '原子创建警务编组并设置首任组长；返回新建的 police_team 单条记录。';

-- 成员离组必须保留历史；当前组长必须先通过组长更换 RPC 完成交接。
create or replace function emergency_resource.remove_police_team_member(
  p_membership_id bigint,
  p_left_at timestamptz default now()
)
returns emergency_resource.police_team_member
language plpgsql
set search_path = emergency_resource, public, pg_temp
as $$
declare
  v_membership emergency_resource.police_team_member%rowtype;
begin
  select *
  into v_membership
  from emergency_resource.police_team_member
  where id = p_membership_id
  for update;

  if not found then
    raise exception 'police team membership % does not exist', p_membership_id
      using errcode = 'P0002';
  end if;

  if v_membership.left_at is not null then
    return v_membership;
  end if;

  if v_membership.member_role = 'leader' then
    raise exception 'current team leader must be replaced before leaving the team'
      using errcode = '23514';
  end if;

  if p_left_at is null or p_left_at < v_membership.joined_at then
    raise exception 'left_at must not be earlier than joined_at'
      using errcode = '22007';
  end if;

  update emergency_resource.police_team_member
  set left_at = p_left_at
  where id = p_membership_id
  returning * into v_membership;

  return v_membership;
end;
$$;

comment on function emergency_resource.remove_police_team_member(bigint, timestamptz) is '记录普通成员或副组长离组并保留历史；返回更新后的 police_team_member 单条记录，当前组长必须先完成交接。';

-- -----------------------------------------------------------------------------
-- PostgREST API 门面
-- -----------------------------------------------------------------------------
create or replace view api.emergency_police_officers as
select
  id, officer_no, name, contact_phone, organization_name, availability_status,
  is_active, metadata, created_at, updated_at, is_simulated
from emergency_resource.police_officer;

create or replace view api.emergency_police_teams as
select
  id, team_code, name, station_id, team_status, description,
  metadata, created_at, updated_at, is_simulated
from emergency_resource.police_team;

create or replace view api.emergency_police_team_members as
select * from emergency_resource.police_team_member;

create or replace view api.emergency_police_team_roster as
select
  tm.id as membership_id,
  tm.team_id,
  t.team_code,
  t.name as team_name,
  t.team_status,
  t.station_id,
  s.source_code as station_source_code,
  s.name as station_name,
  tm.officer_id,
  o.officer_no,
  o.name as officer_name,
  o.contact_phone,
  o.organization_name,
  o.availability_status as officer_availability_status,
  tm.member_role,
  tm.joined_at
from emergency_resource.police_team_member tm
join emergency_resource.police_team t on t.id = tm.team_id
join emergency_resource.police_officer o on o.id = tm.officer_id
left join emergency_resource.police_station s on s.id = t.station_id
where tm.left_at is null;

create or replace view api.emergency_police_team_details as
select
  t.id as team_id,
  t.team_code,
  t.name as team_name,
  t.station_id,
  s.source_code as station_source_code,
  s.name as station_name,
  t.team_status,
  t.description,
  t.is_simulated,
  leader.officer_id as leader_officer_id,
  leader.officer_no as leader_officer_no,
  leader.officer_name as leader_name,
  coalesce(member_stats.active_member_count, 0)::bigint as active_member_count,
  t.metadata,
  t.created_at,
  t.updated_at
from emergency_resource.police_team t
left join emergency_resource.police_station s on s.id = t.station_id
left join lateral (
  select
    tm.officer_id,
    o.officer_no,
    o.name as officer_name
  from emergency_resource.police_team_member tm
  join emergency_resource.police_officer o on o.id = tm.officer_id
  where tm.team_id = t.id
    and tm.member_role = 'leader'
    and tm.left_at is null
  limit 1
) leader on true
left join lateral (
  select count(*) as active_member_count
  from emergency_resource.police_team_member tm
  where tm.team_id = t.id and tm.left_at is null
) member_stats on true;

create or replace view api.emergency_police_team_member_history as
select
  tm.id as membership_id,
  tm.team_id,
  t.team_code,
  t.name as team_name,
  t.station_id,
  s.name as station_name,
  tm.officer_id,
  o.officer_no,
  o.name as officer_name,
  o.organization_name,
  tm.member_role,
  tm.joined_at,
  tm.left_at,
  tm.created_at,
  tm.updated_at
from emergency_resource.police_team_member tm
join emergency_resource.police_team t on t.id = tm.team_id
join emergency_resource.police_officer o on o.id = tm.officer_id
left join emergency_resource.police_station s on s.id = t.station_id;

-- 面向前端的一站式层级结构：每行一个警务站，teams 内嵌编组及当前成员。
create or replace view api.emergency_police_station_team_details as
select
  s.id as station_id,
  s.source_code as station_code,
  s.name as station_name,
  s.station_type,
  s.address,
  s.county_name,
  s.contact_phone,
  s.availability_status,
  s.geom,
  coalesce(team_data.team_count, 0)::bigint as team_count,
  coalesce(team_data.officer_count, 0)::bigint as officer_count,
  coalesce(team_data.teams, '[]'::jsonb) as teams,
  s.created_at,
  s.updated_at
from emergency_resource.police_station s
left join lateral (
  select
    count(*)::bigint as team_count,
    coalesce(sum(team_item.member_count), 0)::bigint as officer_count,
    jsonb_agg(
      jsonb_build_object(
        'team_id', team_item.team_id,
        'team_code', team_item.team_code,
        'team_name', team_item.team_name,
        'team_status', team_item.team_status,
        'is_simulated', team_item.is_simulated,
        'leader_officer_id', team_item.leader_officer_id,
        'leader_officer_no', team_item.leader_officer_no,
        'leader_name', team_item.leader_name,
        'member_count', team_item.member_count,
        'members', team_item.members
      )
      order by team_item.team_name, team_item.team_id
    ) as teams
  from (
    select
      t.id as team_id,
      t.team_code,
      t.name as team_name,
      t.team_status,
      t.is_simulated,
      leader.officer_id as leader_officer_id,
      leader.officer_no as leader_officer_no,
      leader.officer_name as leader_name,
      coalesce(members.member_count, 0)::bigint as member_count,
      coalesce(members.members, '[]'::jsonb) as members
    from emergency_resource.police_team t
    left join lateral (
      select
        tm.officer_id,
        o.officer_no,
        o.name as officer_name
      from emergency_resource.police_team_member tm
      join emergency_resource.police_officer o on o.id = tm.officer_id
      where tm.team_id = t.id
        and tm.member_role = 'leader'
        and tm.left_at is null
      limit 1
    ) leader on true
    left join lateral (
      select
        count(*)::bigint as member_count,
        jsonb_agg(
          jsonb_build_object(
            'membership_id', tm.id,
            'officer_id', o.id,
            'officer_no', o.officer_no,
            'officer_name', o.name,
            'member_role', tm.member_role,
            'contact_phone', o.contact_phone,
            'organization_name', o.organization_name,
            'availability_status', o.availability_status,
            'is_active', o.is_active,
            'is_simulated', o.is_simulated,
            'joined_at', tm.joined_at
          )
          order by
            case tm.member_role
              when 'leader' then 1
              when 'deputy_leader' then 2
              else 3
            end,
            o.officer_no
        ) as members
      from emergency_resource.police_team_member tm
      join emergency_resource.police_officer o on o.id = tm.officer_id
      where tm.team_id = t.id
        and tm.left_at is null
    ) members on true
    where t.station_id = s.id
  ) team_item
) team_data on true;

create or replace function api.assign_police_team_leader(
  p_team_id bigint,
  p_officer_id bigint
)
returns emergency_resource.police_team_member
language sql
volatile
set search_path = emergency_resource, public, pg_temp
as $$
  select * from emergency_resource.assign_police_team_leader(p_team_id, p_officer_id);
$$;

create or replace function api.create_police_team(
  p_team_code text,
  p_name text,
  p_leader_officer_id bigint,
  p_station_id bigint default null,
  p_team_status text default 'active',
  p_description text default null,
  p_is_simulated boolean default false,
  p_metadata jsonb default '{}'::jsonb
)
returns emergency_resource.police_team
language sql
volatile
set search_path = emergency_resource, public, pg_temp
as $$
  select * from emergency_resource.create_police_team(
    p_team_code, p_name, p_leader_officer_id, p_station_id, p_team_status,
    p_description, p_is_simulated, p_metadata
  );
$$;

create or replace function api.remove_police_team_member(
  p_membership_id bigint,
  p_left_at timestamptz default now()
)
returns emergency_resource.police_team_member
language sql
volatile
set search_path = emergency_resource, public, pg_temp
as $$
  select * from emergency_resource.remove_police_team_member(p_membership_id, p_left_at);
$$;

comment on view api.emergency_police_officers is '警员档案 CRUD 资源；联系方式仅向已认证管理角色开放。';
comment on view api.emergency_police_teams is '警务编组 CRUD 资源；station_id 用于挂载现有警务站。';
comment on view api.emergency_police_team_members is '编组成员及任职历史 CRUD 资源；left_at 为空表示当前成员。';
comment on view api.emergency_police_team_roster is '当前警务编组花名册只读资源，包含编组、警务站、警员和成员角色信息。';
comment on view api.emergency_police_team_details is '警务编组后台分页列表，只读返回警务站、当前组长和当前成员数量。';
comment on view api.emergency_police_team_member_history is '警务编组成员任职历史只读资源，包含当前及已离组成员。';
comment on view api.emergency_police_station_team_details is '警务站、关联警务编组及当前编组人员的只读聚合资源；每行对应一个警务站。';
comment on column api.emergency_police_station_team_details.station_id is '警务站 ID。';
comment on column api.emergency_police_station_team_details.team_count is '警务站当前挂载的编组数量。';
comment on column api.emergency_police_station_team_details.officer_count is '警务站下各编组当前成员关系数量；同一警员兼任多个编组时按成员关系重复计数。';
comment on column api.emergency_police_station_team_details.teams is '编组及其当前成员的 JSON 数组；无编组时返回空数组。';
comment on column api.emergency_police_team_roster.membership_id is '当前编组成员关系 ID。';
comment on column api.emergency_police_team_roster.station_id is '编组当前挂载的警务站 ID。';
comment on column api.emergency_police_team_roster.member_role is '当前成员角色：leader、deputy_leader 或 member。';
comment on function api.assign_police_team_leader(bigint, bigint) is '设置或更换警务编组组长；返回 id、team_id、officer_id、member_role、joined_at、left_at、created_at、updated_at 对应的单条成员记录。';
comment on function api.create_police_team(text, text, bigint, bigint, text, text, boolean, jsonb) is '原子创建警务编组并设置首任组长；返回 id、team_code、name、station_id、team_status、description、is_simulated、metadata、created_at、updated_at 对应的单条编组记录。';
comment on function api.remove_police_team_member(bigint, timestamptz) is '记录成员离组；返回 id、team_id、officer_id、member_role、joined_at、left_at、created_at、updated_at 对应的单条成员记录；当前组长必须先完成交接。';

-- -----------------------------------------------------------------------------
-- 权限与 PostgREST schema cache
-- -----------------------------------------------------------------------------
revoke all on emergency_resource.police_officer,
  emergency_resource.police_team,
  emergency_resource.police_team_member
from public, anonymous;
revoke all on function emergency_resource.assign_police_team_leader(bigint, bigint),
  emergency_resource.create_police_team(text, text, bigint, bigint, text, text, boolean, jsonb),
  emergency_resource.remove_police_team_member(bigint, timestamptz)
from public, anonymous;

revoke all on api.emergency_police_officers,
  api.emergency_police_teams,
  api.emergency_police_team_members,
  api.emergency_police_team_roster,
  api.emergency_police_team_details,
  api.emergency_police_team_member_history,
  api.emergency_police_station_team_details
from public, anonymous;
revoke all on function api.assign_police_team_leader(bigint, bigint),
  api.create_police_team(text, text, bigint, bigint, text, text, boolean, jsonb),
  api.remove_police_team_member(bigint, timestamptz)
from public, anonymous;

grant usage on schema emergency_resource, api to admin;
grant select, insert, update, delete on emergency_resource.police_officer,
  emergency_resource.police_team,
  emergency_resource.police_team_member to admin;
grant usage, select, update on sequence emergency_resource.police_officer_id_seq,
  emergency_resource.police_team_id_seq,
  emergency_resource.police_team_member_id_seq to admin;
grant execute on function emergency_resource.assign_police_team_leader(bigint, bigint) to admin;
grant execute on function emergency_resource.create_police_team(text, text, bigint, bigint, text, text, boolean, jsonb) to admin;
grant execute on function emergency_resource.remove_police_team_member(bigint, timestamptz) to admin;

grant select, insert, update, delete on api.emergency_police_officers,
  api.emergency_police_teams,
  api.emergency_police_team_members to admin;
grant select on api.emergency_police_team_roster,
  api.emergency_police_team_details,
  api.emergency_police_team_member_history,
  api.emergency_police_station_team_details to admin;
grant execute on function api.assign_police_team_leader(bigint, bigint) to admin;
grant execute on function api.create_police_team(text, text, bigint, bigint, text, text, boolean, jsonb) to admin;
grant execute on function api.remove_police_team_member(bigint, timestamptz) to admin;

notify pgrst, 'reload schema';

commit;
