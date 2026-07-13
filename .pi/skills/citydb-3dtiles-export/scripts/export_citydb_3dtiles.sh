#!/usr/bin/env bash
set -euo pipefail

# Export 3DCityDB 5.x geometries to 3D Tiles via a citydb-3dtiler-compatible
# materialized view and pg2b3dm. Defaults target the Huaguoshan project DB.

CITYDB_HOST="${CITYDB_HOST:-10.1.109.151}"
CITYDB_PORT="${CITYDB_PORT:-5432}"
CITYDB_NAME="${CITYDB_NAME:-huaguoshan_projd}"
CITYDB_SCHEMA="${CITYDB_SCHEMA:-citydb}"
CITYDB_USER="${CITYDB_USER:-postgres}"
PGPASSWORD="${PGPASSWORD:-postgres}"
export PGPASSWORD

OUTPUT_DIR="${OUTPUT_DIR:-exports/citydb-3dtiler/huaguoshan_3dtiles}"
ADVICE_DIR="${ADVICE_DIR:-exports/citydb-3dtiler}"
MV_NAME="${MV_NAME:-mv_geometries}"
PG2B3DM_VERSION="${PG2B3DM_VERSION:-v2.27.0}"
MAX_FEATURES_PER_TILE="${MAX_FEATURES_PER_TILE:-950}"
TILES_VERSION="${TILES_VERSION:-1.1}"
DEFAULT_COLOR="${DEFAULT_COLOR:-#66DEF3FC}"
DEFAULT_METALLIC_ROUGHNESS="${DEFAULT_METALLIC_ROUGHNESS:-#000000FF}"
RUN_ADVISE="${RUN_ADVISE:-1}"
RUN_VALIDATION="${RUN_VALIDATION:-1}"

# Must be a SQL predicate over aliases f, gd, oc, ns.
FEATURE_WHERE="${FEATURE_WHERE:-f.objectid like 'osm:%' and f.lineage = 'OpenStreetMap via Overpass API' and oc.classname = 'Building'}"

PSQL="${PSQL:-psql}"
PG2B3DM="${PG2B3DM:-}"
CITYDB_3DTILER_REPO="${CITYDB_3DTILER_REPO:-$HOME/.cache/checkouts/github.com/madizm/citydb-3dtiler}"
CACHE_DIR="${CACHE_DIR:-$HOME/.cache/citydb-3dtiles-export}"

if [[ ! "$CITYDB_SCHEMA" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "Invalid CITYDB_SCHEMA: $CITYDB_SCHEMA" >&2
  exit 2
fi
if [[ ! "$MV_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "Invalid MV_NAME: $MV_NAME" >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR" "$ADVICE_DIR" "$CACHE_DIR"

log() { printf '\n==> %s\n' "$*" >&2; }

resolve_pg2b3dm() {
  if [[ -n "$PG2B3DM" && -x "$PG2B3DM" ]]; then
    echo "$PG2B3DM"
    return
  fi
  if command -v pg2b3dm >/dev/null 2>&1; then
    command -v pg2b3dm
    return
  fi

  local os arch asset tool_dir zip_path bin_path
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os:$arch" in
    Darwin:arm64) asset="pg2b3dm-osx-arm64.zip" ;;
    Darwin:x86_64) asset="pg2b3dm-osx-x64.zip" ;;
    Linux:aarch64|Linux:arm64) asset="pg2b3dm-linux-arm64.zip" ;;
    Linux:x86_64) asset="pg2b3dm-linux-x64.zip" ;;
    *) echo "Unsupported platform for automatic pg2b3dm download: $os $arch" >&2; exit 2 ;;
  esac

  tool_dir="$CACHE_DIR/pg2b3dm/$PG2B3DM_VERSION"
  bin_path="$tool_dir/pg2b3dm"
  if [[ ! -x "$bin_path" ]]; then
    mkdir -p "$tool_dir"
    zip_path="$CACHE_DIR/$asset"
    log "Downloading pg2b3dm $PG2B3DM_VERSION ($asset)"
    rm -f "$zip_path"
    if command -v gh >/dev/null 2>&1; then
      gh release download "$PG2B3DM_VERSION" -R Geodan/pg2b3dm -p "$asset" -O "$zip_path" --clobber \
        || curl -fL "https://github.com/Geodan/pg2b3dm/releases/download/$PG2B3DM_VERSION/$asset" -o "$zip_path"
    else
      curl -fL "https://github.com/Geodan/pg2b3dm/releases/download/$PG2B3DM_VERSION/$asset" -o "$zip_path"
    fi
    if [[ ! -s "$zip_path" ]]; then
      echo "Failed to download $asset" >&2
      exit 1
    fi
    unzip -o "$zip_path" -d "$tool_dir" >/dev/null
    chmod +x "$bin_path"
    if [[ ! -x "$bin_path" ]]; then
      echo "pg2b3dm binary was not found after unzip: $bin_path" >&2
      exit 1
    fi
  fi
  echo "$bin_path"
}

run_advice() {
  if [[ "$RUN_ADVISE" != "1" ]]; then
    return
  fi
  if [[ ! -f "$CITYDB_3DTILER_REPO/citydb-3dtiler.py" ]]; then
    log "Skipping advise: citydb-3dtiler checkout not found at $CITYDB_3DTILER_REPO"
    log "Resolve it with librarian: bash checkout.sh https://github.com/madizm/citydb-3dtiler --path-only"
    return
  fi

  log "Running citydb-3dtiler advise"
  (
    cd "$CITYDB_3DTILER_REPO"
    mkdir -p shared
    # Keep generated advice in project output dir by copying afterwards. Symlinking
    # shared across filesystems can be brittle inside containers and temp dirs.
    PGOPTIONS="-c search_path=$CITYDB_SCHEMA,public" \
    uv run --with psycopg2-binary --with PyYAML ./citydb-3dtiler.py \
      --db-host "$CITYDB_HOST" \
      --db-port "$CITYDB_PORT" \
      --db-name "$CITYDB_NAME" \
      --db-schema "$CITYDB_SCHEMA" \
      --db-username "$CITYDB_USER" \
      --db-password "$PGPASSWORD" \
      advise
  )
  if [[ -f "$CITYDB_3DTILER_REPO/shared/advice.yml" ]]; then
    cp "$CITYDB_3DTILER_REPO/shared/advice.yml" "$ADVICE_DIR/advice.yml"
    log "Advice written to $ADVICE_DIR/advice.yml"
  fi
}

create_materialized_view() {
  log "Creating ${CITYDB_SCHEMA}.${MV_NAME} for export"
  local sql_file
  sql_file="$(mktemp)"
  cat > "$sql_file" <<SQL
DROP MATERIALIZED VIEW IF EXISTS ${CITYDB_SCHEMA}.${MV_NAME};

CREATE MATERIALIZED VIEW ${CITYDB_SCHEMA}.${MV_NAME} AS
SELECT DISTINCT ON (gd.id)
       gd.geometry AS geom,
       f.objectid AS id,
       oc.classname AS class,
       ns.alias AS ns,
       jsonb_build_object(
         'PbrMetallicRoughness', jsonb_build_object(
           'BaseColors', ARRAY['${DEFAULT_COLOR}'],
           'MetallicRoughness', ARRAY['${DEFAULT_METALLIC_ROUGHNESS}']
         )
       )::json AS material_data,
       dh.val_double::real AS gen_derivedheight,
       te.val_double::real AS gen_terrainelevation,
       osmurl.val_string AS gen_osmurl
FROM ${CITYDB_SCHEMA}.geometry_data gd
JOIN ${CITYDB_SCHEMA}.feature f ON f.id = gd.feature_id
LEFT JOIN ${CITYDB_SCHEMA}.objectclass oc ON oc.id = f.objectclass_id
LEFT JOIN ${CITYDB_SCHEMA}.namespace ns ON ns.id = oc.namespace_id
LEFT JOIN ${CITYDB_SCHEMA}.property dh ON dh.feature_id = f.id AND dh.name = 'derivedHeight'
LEFT JOIN ${CITYDB_SCHEMA}.property te ON te.feature_id = f.id AND te.name = 'terrainElevation'
LEFT JOIN ${CITYDB_SCHEMA}.property osmurl ON osmurl.feature_id = f.id AND osmurl.name = 'osmUrl'
WHERE (${FEATURE_WHERE})
  AND NOT ST_IsEmpty(gd.geometry)
  AND ST_GeometryType(gd.geometry) NOT IN ('ST_MultiLineString', 'ST_LineString', 'ST_GeometryCollection')
WITH DATA;

CREATE INDEX IF NOT EXISTS ${MV_NAME}_geom_idx
ON ${CITYDB_SCHEMA}.${MV_NAME}
USING gist (st_centroid(st_envelope(geom)));

SELECT count(*) AS export_feature_count FROM ${CITYDB_SCHEMA}.${MV_NAME};
SQL
  "$PSQL" "postgresql://${CITYDB_USER}@${CITYDB_HOST}:${CITYDB_PORT}/${CITYDB_NAME}?connect_timeout=20" -v ON_ERROR_STOP=1 -f "$sql_file"
  rm -f "$sql_file"
}

run_pg2b3dm() {
  local pg2b3dm_bin implicit
  pg2b3dm_bin="$(resolve_pg2b3dm)"
  implicit="true"
  if [[ "$TILES_VERSION" == "1.0" ]]; then
    implicit="false"
  fi

  rm -rf "$OUTPUT_DIR"
  mkdir -p "$OUTPUT_DIR"

  log "Running pg2b3dm: $pg2b3dm_bin"
  "$pg2b3dm_bin" \
    --connection "Host=${CITYDB_HOST};Port=${CITYDB_PORT};Username=${CITYDB_USER};Password=${PGPASSWORD};Database=${CITYDB_NAME};CommandTimeOut=0" \
    --shaderscolumn material_data \
    --table "${CITYDB_SCHEMA}.${MV_NAME}" \
    --column geom \
    --attributecolumns id,class,gen_derivedheight,gen_terrainelevation,gen_osmurl \
    --output "$OUTPUT_DIR" \
    --default_alpha_mode OPAQUE \
    --max_features_per_tile "$MAX_FEATURES_PER_TILE" \
    --use_implicit_tiling "$implicit"
}

validate_tileset() {
  if [[ "$RUN_VALIDATION" != "1" ]]; then
    return
  fi
  if [[ ! -f "$OUTPUT_DIR/tileset.json" ]]; then
    echo "No tileset.json found at $OUTPUT_DIR" >&2
    exit 1
  fi
  log "Validating 3D Tiles"
  npx --yes 3d-tiles-validator \
    --tilesetFile "$OUTPUT_DIR/tileset.json" \
    --outputFile "$OUTPUT_DIR/validation-report.json"
}

summarize() {
  log "Export summary"
  find "$OUTPUT_DIR" -maxdepth 3 -type f -print | sort
}

run_advice
create_materialized_view
run_pg2b3dm
validate_tileset
summarize
