#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
IMAGE=${ANOLIS_IMAGE:-openanolis/anolisos:8.6-x86_64}
PLATFORM=${TARGET_PLATFORM:-linux/amd64}
POSTGREST_VERSION=${POSTGREST_VERSION:-16.3}
BUILD_ROOT=${BUILD_ROOT:-"$ROOT_DIR/deploy/offline-build"}
STAGE="$BUILD_ROOT/huaguoshan-offline"
ARCHIVE="$BUILD_ROOT/huaguoshan-anolis8.6-x86_64-offline.tar.gz"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 1; }
}

require docker
require rsync
require tar
require shasum
require unzip

rm -rf "$STAGE" "$ARCHIVE" "$ARCHIVE.sha256"
mkdir -p "$STAGE"/{app,bin,config,database,docs,rpms,runtime,systemd,wheelhouse} "$BUILD_ROOT/uv-cache"

printf 'Building Anolis 8.6 x86_64 runtime and RPM repository...\n'
docker run --rm -i --platform "$PLATFORM" \
  -e POSTGREST_VERSION="$POSTGREST_VERSION" \
  -e UV_CACHE_DIR=/uv-cache \
  -v "$BUILD_ROOT/uv-cache:/uv-cache" \
  -v "$STAGE:/out" \
  "$IMAGE" bash -s <<'CONTAINER'
set -euo pipefail

dnf install -y dnf-plugins-core createrepo_c curl ca-certificates tar gzip findutils file

dnf module reset -y nginx postgresql
dnf module enable -y nginx:1.22 postgresql:13

dnf download --resolve --alldeps --destdir=/out/rpms \
  nginx postgresql rsync unzip curl ca-certificates openssl
createrepo_c /out/rpms

curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
export UV_PYTHON_INSTALL_DIR=/out/runtime/python
uv python install 3.12
PYTHON_BIN=$(find /out/runtime/python -type f -path '*/bin/python3.12' | head -1)
"$PYTHON_BIN" -m venv /tmp/wheel-builder
/tmp/wheel-builder/bin/pip download --dest /out/wheelhouse \
  'argon2-cffi>=23.1' \
  'fastapi>=0.115' \
  'psycopg[binary]>=3.2' \
  'PyJWT>=2.8' \
  'uvicorn>=0.30' \
  'httpx>=0.27' \
  'websockets>=15,<17'

curl -fL \
  "https://github.com/PostgREST/postgrest/releases/download/v${POSTGREST_VERSION:-16.3}/postgrest-v${POSTGREST_VERSION:-16.3}-linux-static-x86-64.tar.xz" \
  -o /tmp/postgrest.tar.xz
tar -xJf /tmp/postgrest.tar.xz -C /out/bin
chmod 0755 /out/bin/postgrest
file /out/bin/postgrest
/out/bin/postgrest --version
CONTAINER

printf 'Staging application files...\n'
rsync -a \
  --exclude='__pycache__/' \
  --exclude='*.pyc' \
  "$ROOT_DIR/backend" \
  "$ROOT_DIR/docs" \
  "$ROOT_DIR/frontend" \
  "$ROOT_DIR/js" \
  "$ROOT_DIR/scripts" \
  "$ROOT_DIR/tests" \
  "$STAGE/app/"
mkdir -p "$STAGE/app/deploy"
rsync -a "$ROOT_DIR/deploy/docs/" "$STAGE/app/deploy/docs/"
install -m 0644 "$ROOT_DIR/deploy/nginx.conf" "$STAGE/app/deploy/nginx.conf"

if [[ -d "$ROOT_DIR/exports" ]]; then
  rsync -a "$ROOT_DIR/exports/" "$STAGE/app/exports/"
fi

if [[ ! -f "$ROOT_DIR/deploy/dist.zip" ]]; then
  echo 'ERROR: deploy/dist.zip is required' >&2
  exit 1
fi
mkdir -p "$STAGE/app/web/dist/lianyugang-uav"
rm -rf "$BUILD_ROOT/dist-extract"
mkdir -p "$BUILD_ROOT/dist-extract"
unzip -q "$ROOT_DIR/deploy/dist.zip" -d "$BUILD_ROOT/dist-extract"
rsync -a "$BUILD_ROOT/dist-extract/dist/" "$STAGE/app/web/dist/lianyugang-uav/"
cp "$STAGE/app/web/dist/lianyugang-uav/index.html" "$STAGE/app/web/dist/index.html"
rm -rf "$BUILD_ROOT/dist-extract"

if [[ -f "$ROOT_DIR/gv_bestdb_6.1.0.tar.gz" ]]; then
  install -m 0644 "$ROOT_DIR/gv_bestdb_6.1.0.tar.gz" "$STAGE/database/gv_bestdb_6.1.0.tar.gz"
fi

install -m 0644 "$ROOT_DIR/deploy/offline/auth.env.example" "$STAGE/config/auth.env.example"
install -m 0644 "$ROOT_DIR/deploy/offline/risk-engine.env.example" "$STAGE/config/risk-engine.env.example"
install -m 0644 "$ROOT_DIR/deploy/offline/radar-cloud.env.example" "$STAGE/config/radar-cloud.env.example"
install -m 0644 "$ROOT_DIR/deploy/offline/lizheng-connector.env.example" "$STAGE/config/lizheng-connector.env.example"
install -m 0644 "$ROOT_DIR/deploy/offline/postgrest.conf.example" "$STAGE/config/postgrest.conf.example"
install -m 0644 "$ROOT_DIR/deploy/offline/huaguoshan-auth.service" "$STAGE/systemd/huaguoshan-auth.service"
install -m 0644 "$ROOT_DIR/deploy/offline/huaguoshan-risk-engine.service" "$STAGE/systemd/huaguoshan-risk-engine.service"
install -m 0644 "$ROOT_DIR/deploy/offline/huaguoshan-postgrest.service" "$STAGE/systemd/huaguoshan-postgrest.service"
install -m 0644 "$ROOT_DIR/deploy/offline/huaguoshan-radar-cloud.service" "$STAGE/systemd/huaguoshan-radar-cloud.service"
install -m 0644 "$ROOT_DIR/deploy/offline/huaguoshan-lizheng-connector.service" "$STAGE/systemd/huaguoshan-lizheng-connector.service"
install -m 0755 "$ROOT_DIR/deploy/offline/install.sh" "$STAGE/install.sh"
install -m 0644 "$ROOT_DIR/deploy/offline/README.md" "$STAGE/README.md"

{
  echo "build_time_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "target_os=Anolis OS 8.6"
  echo "target_arch=x86_64"
  echo "target_glibc=2.28"
  echo "container_image=$IMAGE"
  echo "container_platform=$PLATFORM"
  echo "postgrest_version=$POSTGREST_VERSION"
  echo "git_commit=$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "git_dirty=$(test -n "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null)" && echo true || echo false)"
} > "$STAGE/BUILD-INFO.txt"

{
  echo '# Included tilesets'
  find "$STAGE/app/exports" -name tileset.json -print 2>/dev/null | sed "s#$STAGE/app/##" | sort || true
  echo
  echo '# Expected but missing W/G airspace tilesets'
  for kind in candidate suitable; do
    for level in 19 20 21 22; do
      path="exports/airspace/wg_gger/$kind/level-$level/tileset.json"
      [[ -f "$STAGE/app/$path" ]] || echo "$path"
    done
  done
} > "$STAGE/TILESET-INVENTORY.txt"

printf 'Validating staged runtime under Anolis...\n'
docker run --rm -i --platform "$PLATFORM" \
  -v "$STAGE:/bundle:ro" \
  "$IMAGE" bash -s <<'CONTAINER'
set -euo pipefail
PYTHON_BIN=$(find /bundle/runtime/python -type f -path '*/bin/python3.12' | head -1)
test "$(uname -m)" = x86_64
"$PYTHON_BIN" --version
/bundle/bin/postgrest --version
test -f /bundle/app/frontend/tianditu-3d.html
test -f /bundle/app/web/dist/index.html
test -f /bundle/app/deploy/nginx.conf
CONTAINER

printf 'Generating checksums and archive...\n'
test -n "$(find "$STAGE/rpms" -name '*.rpm' -print -quit)"
test -n "$(find "$STAGE/runtime/python" -type f -path '*/bin/python3.12' -print -quit)"
test -n "$(find "$STAGE/wheelhouse" -type f -name '*.whl' -print -quit)"
test -x "$STAGE/bin/postgrest"
(
  cd "$STAGE"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS
)
tar -C "$BUILD_ROOT" -czf "$ARCHIVE" "$(basename "$STAGE")"
(
  cd "$BUILD_ROOT"
  shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256"
)

printf '\nOffline bundle created:\n  %s\n  %s\n' "$ARCHIVE" "$ARCHIVE.sha256"
du -sh "$STAGE" "$ARCHIVE"
