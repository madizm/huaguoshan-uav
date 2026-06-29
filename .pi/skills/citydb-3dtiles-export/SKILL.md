---
name: citydb-3dtiles-export
description: Export 3DCityDB 5.x data to 3D Tiles using citydb-3dtiler and pg2b3dm. Use when asked to publish/imported 3DCityDB buildings or terrain-aware LoD1 solids as Cesium/3D Tiles, especially the Huaguoshan workflow.
compatibility: Requires PostgreSQL/PostGIS access, psql, uv, Docker or local Python, pg2b3dm, and optionally npx 3d-tiles-validator.
---

# citydb-3dtiles-export

This skill exports 3DCityDB 5.x geometry into 3D Tiles using the `citydb-3dtiler` workflow and the `pg2b3dm` tiling backend.

Use it for:

- 3DCityDB 5.x `citydb.feature` + `citydb.geometry_data` exports.
- OSM-derived LoD1 building solids stored as `POLYHEDRALSURFACE Z`.
- Terrain-aware building exports where building `z` already uses DEM-derived `base_z`.
- Generating Cesium-compatible 3D Tiles and validating `tileset.json`.

Do **not** describe the exported data as LiDAR, photogrammetry, authoritative city model data, or 3D Tiles source data. The export is a derived visualization/streaming format from the existing 3DCityDB contents.

## Recommended workflow

1. Confirm current 3DCityDB content and target object classes.
2. Resolve or refresh `citydb-3dtiler` via the librarian skill.
3. Generate `advice.yml` using `citydb-3dtiler advise`.
4. Create an export materialized view with explicit schema-qualified tables.
5. Run `pg2b3dm` against that materialized view.
6. Validate the generated tileset with `3d-tiles-validator`.
7. Keep generated tiles under an ignored output directory unless explicitly asked to commit them.

The helper script implements this optimized path:

```bash
bash .pi/skills/citydb-3dtiles-export/scripts/export_citydb_3dtiles.sh
```

## Huaguoshan defaults

The helper script defaults to the current Huaguoshan database:

```text
host: 10.1.109.151
port: 5432
database: huaguoshan_projd
schema: citydb
user: postgres
password env/default: PGPASSWORD / postgres
output: exports/citydb-3dtiler/huaguoshan_3dtiles
feature filter: OSM Building features only
```

Override with environment variables, for example:

```bash
CITYDB_HOST=10.1.109.151 \
CITYDB_PORT=5432 \
CITYDB_NAME=huaguoshan_projd \
CITYDB_SCHEMA=citydb \
CITYDB_USER=postgres \
PGPASSWORD=postgres \
OUTPUT_DIR=exports/citydb-3dtiler/huaguoshan_3dtiles \
bash .pi/skills/citydb-3dtiles-export/scripts/export_citydb_3dtiles.sh
```

## Important implementation notes

### Schema search path

`citydb-3dtiler` SQL often references tables such as `feature` and `geometry_data` without schema qualification. Use:

```bash
PGOPTIONS='-c search_path=citydb,public'
```

for `citydb-3dtiler advise`.

### PostgreSQL 13 compatibility

Some `citydb-3dtiler` style SQL uses SQL/JSON syntax such as:

```sql
JSON_OBJECT('key' : value ABSENT ON NULL RETURNING json)
```

That syntax is not supported by PostgreSQL 13. The optimized workflow avoids relying on those style views during tiling by creating a simple materialized view with `jsonb_build_object(...)::json AS material_data`, then calling `pg2b3dm` directly.

### Materialized view contract

The export view should provide at least:

```text
geom              PostGIS 3D geometry
id                feature object id / exported feature id
class             object class name
material_data     pg2b3dm material JSON
```

Optional metadata attributes can be added, e.g.:

```text
gen_derivedheight
gen_terrainelevation
gen_osmurl
```

### 3D Tiles validation

Run:

```bash
npx --yes 3d-tiles-validator \
  --tilesetFile exports/citydb-3dtiler/huaguoshan_3dtiles/tileset.json \
  --outputFile exports/citydb-3dtiler/huaguoshan_3dtiles/validation-report.json
```

Acceptable current result for the Huaguoshan export:

```text
errors: 0
warnings: 0
```

Validator `INFO` entries about unsupported `EXT_structural_metadata` / `EXT_mesh_features` are informational for the validator version and are not export failures.

## Expected Huaguoshan output

For the current OSM + DEM implementation:

```text
exports/citydb-3dtiler/huaguoshan_3dtiles/tileset.json
exports/citydb-3dtiler/huaguoshan_3dtiles/content/0_0_0.glb
exports/citydb-3dtiler/huaguoshan_3dtiles/subtrees/0_0_0.subtree
exports/citydb-3dtiler/huaguoshan_3dtiles/validation-report.json
```

Current baseline:

```text
Building features: 17
3D Tiles version: 1.1
Implicit tiling: enabled
Validation errors: 0
Validation warnings: 0
```

## Troubleshooting

- `relation "feature" does not exist`: set `PGOPTIONS='-c search_path=citydb,public'` or schema-qualify SQL.
- `syntax error at or near ":"` in `JSON_OBJECT`: database is too old for the SQL/JSON syntax; use the helper script's `jsonb_build_object` materialized view path.
- Docker intermittently cannot reach `10.1.109.151`: prefer local `pg2b3dm` binary, or retry with `--network host` on Linux where supported.
- `pg2b3dm` missing: install or download a release from `Geodan/pg2b3dm`; the helper script can download via `gh` when available.
- Empty tileset: verify the materialized view row count and that `geometry_data.geometry` contains non-empty 3D geometries.
