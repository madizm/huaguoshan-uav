#!/usr/bin/env bash
set -euo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo 'ERROR: run this installer as root' >&2
  exit 1
fi

BUNDLE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APP_DIR=/mnt/project/huaguoshan
OPT_DIR=/opt/huaguoshan
CONFIG_DIR=/etc/huaguoshan
SERVICE_USER=huaguoshan

if grep -RqsE '<DATABASE_|<SAME_RANDOM_' "$BUNDLE_DIR/config"; then
  echo 'NOTE: configuration templates still contain placeholders.'
fi

printf 'Verifying bundle checksums...\n'
(cd "$BUNDLE_DIR" && sha256sum --quiet -c SHA256SUMS)

printf 'Installing Anolis RPM packages...\n'
dnf install -y \
  --disablerepo='*' \
  --repofrompath="huaguoshan-offline,file://$BUNDLE_DIR/rpms" \
  --enablerepo='huaguoshan-offline' \
  --setopt='huaguoshan-offline.gpgcheck=0' \
  --setopt='huaguoshan-offline.module_hotfixes=true' \
  nginx postgresql rsync unzip curl ca-certificates openssl

if ! getent group "$SERVICE_USER" >/dev/null; then
  groupadd --system "$SERVICE_USER"
fi
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --gid "$SERVICE_USER" --home-dir "$OPT_DIR" --shell /sbin/nologin "$SERVICE_USER"
fi

install -d -m 0755 "$APP_DIR" "$OPT_DIR" "$OPT_DIR/runtime" "$CONFIG_DIR"
rsync -a --delete "$BUNDLE_DIR/app/" "$APP_DIR/"
rsync -a --delete "$BUNDLE_DIR/runtime/python/" "$OPT_DIR/python/"
install -m 0755 "$BUNDLE_DIR/bin/postgrest" /usr/local/bin/postgrest

PYTHON_BIN=$(find "$OPT_DIR/python" -type f -path '*/bin/python3.12' | head -1)
if [[ -z "$PYTHON_BIN" ]]; then
  echo 'ERROR: bundled Python 3.12 runtime not found' >&2
  exit 1
fi

rm -rf "$OPT_DIR/runtime"
"$PYTHON_BIN" -m venv --copies "$OPT_DIR/runtime"
"$OPT_DIR/runtime/bin/pip" install \
  --no-index \
  --find-links="$BUNDLE_DIR/wheelhouse" \
  argon2-cffi fastapi 'psycopg[binary]' PyJWT uvicorn httpx 'websockets>=15,<17'

if [[ ! -f "$CONFIG_DIR/auth.env" ]]; then
  install -m 0600 "$BUNDLE_DIR/config/auth.env.example" "$CONFIG_DIR/auth.env"
fi
if [[ ! -f "$CONFIG_DIR/risk-engine.env" ]]; then
  install -m 0600 "$BUNDLE_DIR/config/risk-engine.env.example" "$CONFIG_DIR/risk-engine.env"
fi
if [[ ! -f "$CONFIG_DIR/postgrest.conf" ]]; then
  install -m 0600 "$BUNDLE_DIR/config/postgrest.conf.example" "$CONFIG_DIR/postgrest.conf"
fi
if [[ ! -f "$CONFIG_DIR/radar-cloud.env" ]]; then
  install -m 0600 "$BUNDLE_DIR/config/radar-cloud.env.example" "$CONFIG_DIR/radar-cloud.env"
fi
if [[ ! -f "$CONFIG_DIR/lizheng-connector.env" ]]; then
  install -m 0600 "$BUNDLE_DIR/config/lizheng-connector.env.example" "$CONFIG_DIR/lizheng-connector.env"
fi

install -m 0644 "$BUNDLE_DIR/systemd/huaguoshan-auth.service" /etc/systemd/system/huaguoshan-auth.service
install -m 0644 "$BUNDLE_DIR/systemd/huaguoshan-risk-engine.service" /etc/systemd/system/huaguoshan-risk-engine.service
install -m 0644 "$BUNDLE_DIR/systemd/huaguoshan-postgrest.service" /etc/systemd/system/huaguoshan-postgrest.service
install -m 0644 "$BUNDLE_DIR/systemd/huaguoshan-radar-cloud.service" /etc/systemd/system/huaguoshan-radar-cloud.service
install -m 0644 "$BUNDLE_DIR/systemd/huaguoshan-lizheng-connector.service" /etc/systemd/system/huaguoshan-lizheng-connector.service
install -m 0644 "$APP_DIR/deploy/nginx.conf" /etc/nginx/nginx.conf

chown -R root:root "$APP_DIR"
find "$APP_DIR" -type d -exec chmod 0755 {} +
chown -R root:root "$OPT_DIR/python" "$OPT_DIR/runtime"
chmod 0600 "$CONFIG_DIR/auth.env" "$CONFIG_DIR/risk-engine.env" "$CONFIG_DIR/postgrest.conf" "$CONFIG_DIR/radar-cloud.env" "$CONFIG_DIR/lizheng-connector.env"

if [[ ${SKIP_SYSTEMD_RELOAD:-0} != 1 ]]; then
  systemctl daemon-reload
fi

cat <<EOF

Files installed. Before starting services:

1. Replace every placeholder in:
   $CONFIG_DIR/auth.env
   $CONFIG_DIR/risk-engine.env
   $CONFIG_DIR/postgrest.conf
   $CONFIG_DIR/radar-cloud.env
   $CONFIG_DIR/lizheng-connector.env
2. Ensure `auth.env` and `postgrest.conf` use exactly the same JWT secret; `risk-engine.env` uses the separate database password for `risk_engine`.
3. Ensure PostgreSQL is reachable and database migrations are complete.
4. Validate Nginx:
   nginx -t
5. Start services:
   systemctl enable --now huaguoshan-auth huaguoshan-postgrest nginx
6. Start the risk engine worker after applying the risk-assessment migrations:
   systemctl enable --now huaguoshan-risk-engine
7. Start the detection connectors:
   systemctl enable --now huaguoshan-radar-cloud
   systemctl enable --now huaguoshan-lizheng-connector
8. Verify:
   curl -fsS http://127.0.0.1:20000/healthz

Services were intentionally not started because credentials are not bundled.
EOF
