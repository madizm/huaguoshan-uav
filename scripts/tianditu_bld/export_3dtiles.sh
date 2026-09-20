#!/usr/bin/env bash
# 天地图建筑白膜导出 3D Tiles：raw.tianditu_bld_whitemodel_export → pg2b3dm → 校验。
# 复用 citydb-3dtiles-export 技能的 pg2b3dm 获取与校验方式。
set -euo pipefail

DB_HOST="${CITYDB_HOST:-10.1.109.151}"
DB_PORT="${CITYDB_PORT:-5432}"
DB_NAME="${CITYDB_NAME:-huaguoshan_projd}"
DB_USER="${CITYDB_USER:-postgres}"
PGPASSWORD="${PGPASSWORD:-postgres}"
export PGPASSWORD

OUTPUT_DIR="${OUTPUT_DIR:-exports/tianditu-bld-3dtiles}"
MAX_FEATURES_PER_TILE="${MAX_FEATURES_PER_TILE:-400}"
PG2B3DM_VERSION="${PG2B3DM_VERSION:-v2.27.0}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"

log() { echo "[export-tianditu-bld] $*" >&2; }

resolve_pg2b3dm() {
  if command -v pg2b3dm >/dev/null 2>&1; then
    command -v pg2b3dm
    return
  fi
  local os arch asset
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os:$arch" in
    Darwin:arm64) asset="pg2b3dm-osx-arm64.zip" ;;
    Darwin:x86_64) asset="pg2b3dm-osx-x64.zip" ;;
    Linux:aarch64|Linux:arm64) asset="pg2b3dm-linux-arm64.zip" ;;
    Linux:x86_64) asset="pg2b3dm-linux-x64.zip" ;;
    *) echo "Unsupported platform: $os $arch" >&2; exit 2 ;;
  esac
  local tool_dir="$CACHE_DIR/pg2b3dm/$PG2B3DM_VERSION"
  local bin_path="$tool_dir/pg2b3dm"
  if [[ ! -x "$bin_path" ]]; then
    mkdir -p "$tool_dir"
    log "Downloading pg2b3dm $PG2B3DM_VERSION ($asset)"
    curl -fL "https://github.com/Geodan/pg2b3dm/releases/download/$PG2B3DM_VERSION/$asset" -o "$tool_dir/$asset"
    (cd "$tool_dir" && unzip -o "$asset" && chmod +x pg2b3dm)
  fi
  echo "$bin_path"
}

PG2B3DM_BIN="$(resolve_pg2b3dm)"

log "Refreshing materialized view"
psql "postgresql://${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}?connect_timeout=20" -v ON_ERROR_STOP=1 \
  -c "refresh materialized view raw.tianditu_bld_whitemodel_export;" \
  -c "select count(*) as export_feature_count from raw.tianditu_bld_whitemodel_export;"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

log "Running pg2b3dm: $PG2B3DM_BIN"
"$PG2B3DM_BIN" \
  --connection "Host=${DB_HOST};Port=${DB_PORT};Username=${DB_USER};Password=${PGPASSWORD};Database=${DB_NAME};CommandTimeOut=0" \
  --shaderscolumn material_data \
  --table "raw.tianditu_bld_whitemodel_export" \
  --column geom \
  --attributecolumns id,class,gen_floor,gen_height_m,gen_base_z \
  --output "$OUTPUT_DIR" \
  --default_alpha_mode OPAQUE \
  --max_features_per_tile "$MAX_FEATURES_PER_TILE" \
  --use_implicit_tiling true

log "Validating 3D Tiles"
npx --yes 3d-tiles-validator \
  --tilesetFile "$OUTPUT_DIR/tileset.json" \
  --outputFile "$OUTPUT_DIR/validation-report.json" || true

log "Done: $OUTPUT_DIR"
find "$OUTPUT_DIR" -maxdepth 2 -type f | sort | head -20
