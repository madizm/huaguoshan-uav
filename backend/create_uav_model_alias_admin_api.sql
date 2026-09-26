-- 无人机机型匹配规则管理 API
-- 依赖 expand_uav_model_catalog_with_alias.sql；可安全重复执行

begin;

-- 1. 创建统计视图（含命中次数）
create or replace view api.uav_model_alias_statistics as
select 
    a.alias_pattern,
    a.model_code,
    a.priority,
    m.name as model_name,
    m.manufacturer,
    coalesce(stats.match_count, 0) as match_count,
    a.created_at
from equipment.uav_model_alias a
join equipment.device_model m on a.model_code = m.model_code
left join lateral (
    select count(*) as match_count
    from situation.target_observation o
    where o.model ilike a.alias_pattern
) stats on true
order by a.priority desc, a.alias_pattern;

comment on view api.uav_model_alias_statistics is '机型匹配规则统计视图，包含命中次数';

-- 2. 创建规则函数
create or replace function api.create_uav_model_alias(
    p_alias_pattern text,
    p_model_code text,
    p_priority integer
)
returns jsonb
language plpgsql
security definer
as $$
declare
    v_result jsonb;
begin
    -- 验证输入
    if p_alias_pattern is null or p_alias_pattern = '' then
        raise exception '匹配模式不能为空';
    end if;
    
    if p_model_code is null or p_model_code = '' then
        raise exception '标准机型不能为空';
    end if;
    
    if p_priority is null then
        raise exception '优先级不能为空';
    end if;
    
    -- 验证标准机型是否存在
    if not exists (select 1 from equipment.device_model where model_code = p_model_code and category_code = 'uav') then
        raise exception '标准机型不存在: %', p_model_code;
    end if;
    
    -- 插入规则
    insert into equipment.uav_model_alias (alias_pattern, model_code, priority)
    values (p_alias_pattern, p_model_code, p_priority)
    returning jsonb_build_object(
        'alias_pattern', alias_pattern,
        'model_code', model_code,
        'priority', priority
    ) into v_result;
    
    return v_result;
end;
$$;

comment on function api.create_uav_model_alias is '创建机型匹配规则';

-- 3. 更新规则函数
create or replace function api.update_uav_model_alias(
    p_old_alias_pattern text,
    p_new_alias_pattern text,
    p_model_code text,
    p_priority integer
)
returns jsonb
language plpgsql
security definer
as $$
declare
    v_result jsonb;
begin
    -- 验证输入
    if p_old_alias_pattern is null or p_old_alias_pattern = '' then
        raise exception '原匹配模式不能为空';
    end if;
    
    if p_new_alias_pattern is null or p_new_alias_pattern = '' then
        raise exception '新匹配模式不能为空';
    end if;
    
    if p_model_code is null or p_model_code = '' then
        raise exception '标准机型不能为空';
    end if;
    
    if p_priority is null then
        raise exception '优先级不能为空';
    end if;
    
    -- 验证标准机型是否存在
    if not exists (select 1 from equipment.device_model where model_code = p_model_code and category_code = 'uav') then
        raise exception '标准机型不存在: %', p_model_code;
    end if;
    
    -- 更新规则
    update equipment.uav_model_alias
    set alias_pattern = p_new_alias_pattern,
        model_code = p_model_code,
        priority = p_priority
    where alias_pattern = p_old_alias_pattern
    returning jsonb_build_object(
        'alias_pattern', alias_pattern,
        'model_code', model_code,
        'priority', priority
    ) into v_result;
    
    if v_result is null then
        raise exception '规则不存在: %', p_old_alias_pattern;
    end if;
    
    return v_result;
end;
$$;

comment on function api.update_uav_model_alias is '更新机型匹配规则';

-- 4. 删除规则函数
create or replace function api.delete_uav_model_alias(p_alias_pattern text)
returns void
language plpgsql
security definer
as $$
begin
    if p_alias_pattern is null or p_alias_pattern = '' then
        raise exception '匹配模式不能为空';
    end if;
    
    delete from equipment.uav_model_alias
    where alias_pattern = p_alias_pattern;
    
    if not found then
        raise exception '规则不存在: %', p_alias_pattern;
    end if;
end;
$$;

comment on function api.delete_uav_model_alias is '删除机型匹配规则';

-- 5. 测试匹配函数
create or replace function api.test_uav_model_match(p_model text)
returns jsonb
language plpgsql
as $$
declare
    v_matched_model_code text;
    v_matched_model_name text;
    v_matched_manufacturer text;
    v_matched_weight_class text;
    v_matched_max_takeoff_weight_kg numeric;
    v_result jsonb;
begin
    if p_model is null or p_model = '' then
        return jsonb_build_object('matched', false, 'reason', '输入为空');
    end if;
    
    -- 调用匹配函数
    v_matched_model_code := equipment.match_uav_model(p_model);
    
    if v_matched_model_code is null then
        return jsonb_build_object('matched', false, 'reason', '无匹配规则');
    end if;
    
    -- 获取匹配的机型信息
    select m.name, m.manufacturer, s.weight_class, s.max_takeoff_weight_kg
    into v_matched_model_name, v_matched_manufacturer, v_matched_weight_class, v_matched_max_takeoff_weight_kg
    from equipment.device_model m
    join equipment.uav_model_spec s on m.model_code = s.model_code
    where m.model_code = v_matched_model_code;
    
    return jsonb_build_object(
        'matched', true,
        'model_code', v_matched_model_code,
        'model_name', v_matched_model_name,
        'manufacturer', v_matched_manufacturer,
        'weight_class', v_matched_weight_class,
        'max_takeoff_weight_kg', v_matched_max_takeoff_weight_kg
    );
end;
$$;

comment on function api.test_uav_model_match is '测试机型匹配规则';

-- 6. 权限设置
grant select on api.uav_model_alias_statistics to admin;
grant execute on function api.create_uav_model_alias to admin;
grant execute on function api.update_uav_model_alias to admin;
grant execute on function api.delete_uav_model_alias to admin;
grant execute on function api.test_uav_model_match to admin;

commit;
