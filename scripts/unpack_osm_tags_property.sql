-- Unpack legacy OSM tag JSON stored in citydb.property.name = 'osmTags'.
--
-- Converts each legacy JSON row into a GenericAttributeSet parent
-- (datatype_id = 200) and creates one child String property per OSM tag.
-- Safe to run after the importer has already been updated: rows that no longer
-- carry JSON in val_string/val_content are ignored.

begin;

with source as (
    select
        p.id,
        p.feature_id,
        coalesce(p.val_string, p.val_content)::jsonb as tags
    from citydb.property p
    where p.name = 'osmTags'
      and (p.val_string is not null or p.val_content is not null)
      and jsonb_typeof(coalesce(p.val_string, p.val_content)::jsonb) = 'object'
), deleted_existing_children as (
    delete from citydb.property child
    using source parent
    where child.parent_id = parent.id
    returning child.id
), inserted_children as (
    insert into citydb.property
      (feature_id, parent_id, datatype_id, namespace_id, name, val_string)
    select
        source.feature_id,
        source.id,
        5,
        3,
        tag.key,
        tag.value
    from source
    cross join lateral jsonb_each_text(source.tags) as tag(key, value)
    order by source.id, tag.key
    returning id
), updated_parents as (
    update citydb.property p
    set datatype_id = 200,
        namespace_id = 3,
        val_string = null,
        val_content = null,
        val_content_mime_type = null
    from source
    where p.id = source.id
    returning p.id
)
select
    (select count(*) from source) as unpacked_osm_tags_rows,
    (select count(*) from deleted_existing_children) as deleted_existing_children,
    (select count(*) from inserted_children) as inserted_tag_properties,
    (select count(*) from updated_parents) as converted_parent_rows;

commit;

-- Query example:
-- select f.objectid, parent.id as osm_tags_id, child.name as osm_tag_key, child.val_string as osm_tag_value
-- from citydb.property parent
-- join citydb.property child on child.parent_id = parent.id
-- join citydb.feature f on f.id = parent.feature_id
-- where parent.name = 'osmTags'
-- order by f.objectid, child.name;
