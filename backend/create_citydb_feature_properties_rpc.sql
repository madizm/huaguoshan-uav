-- PostgREST RPC: fetch a CityDB feature and its property tree for a picked 3D Tiles feature.
--
-- Usage through PostgREST:
--   POST /rpc/get_citydb_feature_properties
--   {"p_feature_identifier":"osm:way:123"}
--
-- The identifier can be citydb.feature.id, objectid, or identifier. The frontend
-- passes the value read from 3D Tiles metadata, usually the `id` property or
-- `gen_osmurl` fallback exported by pg2b3dm.

begin;

create or replace function public.get_citydb_feature_properties(p_feature_identifier text)
returns jsonb
language sql
stable
security definer
set search_path = public, citydb, pg_temp
as $$
with matched_feature as (
    select f.*
    from citydb.feature f
    where f.objectid = p_feature_identifier
       or f.identifier = p_feature_identifier
       or (
            p_feature_identifier ~ '^[0-9]+$'
            and f.id = p_feature_identifier::bigint
       )
    order by
        case
            when f.objectid = p_feature_identifier then 1
            when f.identifier = p_feature_identifier then 2
            else 3
        end,
        f.id
    limit 1
), property_rows as (
    select
        p.id,
        p.feature_id,
        p.parent_id,
        p.datatype_id,
        d.typename as datatype,
        p.namespace_id,
        n.alias as namespace_alias,
        n.namespace,
        p.name,
        case
            when p.val_int is not null then to_jsonb(p.val_int)
            when p.val_double is not null then to_jsonb(p.val_double)
            when p.val_string is not null then to_jsonb(p.val_string)
            when p.val_timestamp is not null then to_jsonb(p.val_timestamp)
            when p.val_uri is not null then to_jsonb(p.val_uri)
            when p.val_codespace is not null then to_jsonb(p.val_codespace)
            when p.val_uom is not null then to_jsonb(p.val_uom)
            when p.val_array is not null then p.val_array
            when p.val_lod is not null then to_jsonb(p.val_lod)
            when p.val_geometry_id is not null then to_jsonb(p.val_geometry_id)
            when p.val_implicitgeom_id is not null then to_jsonb(p.val_implicitgeom_id)
            when p.val_appearance_id is not null then to_jsonb(p.val_appearance_id)
            when p.val_address_id is not null then to_jsonb(p.val_address_id)
            when p.val_feature_id is not null then to_jsonb(p.val_feature_id)
            when p.val_relation_type is not null then to_jsonb(p.val_relation_type)
            when p.val_content is not null then to_jsonb(p.val_content)
            else null::jsonb
        end as value,
        p.val_uom as uom,
        p.val_codespace as codespace,
        p.val_content_mime_type as content_mime_type
    from citydb.property p
    join matched_feature f on f.id = p.feature_id
    left join citydb.datatype d on d.id = p.datatype_id
    left join citydb.namespace n on n.id = p.namespace_id
), child_properties as (
    select
        child.parent_id,
        jsonb_agg(
            jsonb_strip_nulls(jsonb_build_object(
                'id', child.id,
                'name', child.name,
                'datatype_id', child.datatype_id,
                'datatype', child.datatype,
                'namespace_id', child.namespace_id,
                'namespace_alias', child.namespace_alias,
                'value', child.value,
                'uom', child.uom,
                'codespace', child.codespace,
                'content_mime_type', child.content_mime_type
            ))
            order by child.name, child.id
        ) as children
    from property_rows child
    where child.parent_id is not null
    group by child.parent_id
), top_properties as (
    select jsonb_agg(
        jsonb_strip_nulls(jsonb_build_object(
            'id', parent.id,
            'name', parent.name,
            'datatype_id', parent.datatype_id,
            'datatype', parent.datatype,
            'namespace_id', parent.namespace_id,
            'namespace_alias', parent.namespace_alias,
            'namespace', parent.namespace,
            'value', parent.value,
            'uom', parent.uom,
            'codespace', parent.codespace,
            'content_mime_type', parent.content_mime_type,
            'children', child_properties.children
        ))
        order by parent.name, parent.id
    ) as properties
    from property_rows parent
    left join child_properties on child_properties.parent_id = parent.id
    where parent.parent_id is null
)
select case
    when not exists (select 1 from matched_feature) then null::jsonb
    else jsonb_build_object(
        'feature', (
            select jsonb_strip_nulls(jsonb_build_object(
                'id', f.id,
                'objectid', f.objectid,
                'identifier', f.identifier,
                'identifier_codespace', f.identifier_codespace,
                'objectclass_id', f.objectclass_id,
                'objectclass', oc.classname,
                'lineage', f.lineage,
                'creation_date', f.creation_date,
                'last_modification_date', f.last_modification_date
            ))
            from matched_feature f
            left join citydb.objectclass oc on oc.id = f.objectclass_id
        ),
        'properties', coalesce((select properties from top_properties), '[]'::jsonb)
    )
end;
$$;

comment on function public.get_citydb_feature_properties(text)
is 'Fetch a CityDB feature and nested citydb.property rows for a picked 3D Tiles metadata identifier.';

grant execute on function public.get_citydb_feature_properties(text) to admin;

-- PostgREST uses the first exposed schema in pgrest.conf (`citydb`) as the
-- default RPC schema. Keep the main implementation in `public`, and expose this
-- thin wrapper so `/rpc/get_citydb_feature_properties` works without custom
-- Content-Profile headers.
create or replace function citydb.get_citydb_feature_properties(p_feature_identifier text)
returns jsonb
language sql
stable
security definer
set search_path = public, citydb, pg_temp
as $$
    select public.get_citydb_feature_properties(p_feature_identifier);
$$;

comment on function citydb.get_citydb_feature_properties(text)
is 'PostgREST wrapper for public.get_citydb_feature_properties(text).';

grant execute on function citydb.get_citydb_feature_properties(text) to admin;

notify pgrst, 'reload schema';

commit;
