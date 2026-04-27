#!/usr/bin/env bash
set -euo pipefail

TOKEN=""
DOMAIN=""

usage() {
  echo "Usage: $0 -t <token> -d <domain>"
  echo "   or: $0 --token <token> --domain <domain>"
  exit 1
}

if [ "$#" -eq 0 ]; then
  usage
fi

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -t|--token)
      TOKEN="${2:-}"
      shift 2
      ;;
    -d|--domain)
      DOMAIN="${2:-}"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1"
      usage
      ;;
    *)
      echo "Unexpected argument: $1"
      usage
      ;;
  esac
done

if [ -z "$TOKEN" ] || [ -z "$DOMAIN" ]; then
  echo "Error: --token and --domain are required."
  usage
fi

BASE_DIR="/root"
TARGET_DIR="${BASE_DIR}/backhaul_v2"
URL="https://github.com/Musixal/Backhaul/releases/download/v0.7.2/backhaul_linux_amd64.tar.gz"
ARCHIVE_FILE="backhaul_linux_amd64.tar.gz"
SERVICE_NAME="backhaul_v2.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

echo "Using target directory: $TARGET_DIR"
mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"

echo "Downloading backhaul from $URL ..."
wget -O "$ARCHIVE_FILE" "$URL"

echo "Extracting $ARCHIVE_FILE ..."
tar -xzf "$ARCHIVE_FILE"

chmod +x backhaul

cat > config.toml <<EOF
[client]
remote_addr = "${DOMAIN}:80"
transport = "wsmux"
token = "${TOKEN}"
connection_pool = 2
aggressive_pool = true
keepalive_period = 60
dial_timeout = 15
retry_interval = 5
nodelay = true
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536
log_level = "info"
EOF

echo "config.toml created."

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Backhaul Client Service
After=network.target

[Service]
Type=simple
WorkingDirectory=${TARGET_DIR}
ExecStart=${TARGET_DIR}/backhaul -c ${TARGET_DIR}/config.toml
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

echo "Systemd service created at $SERVICE_FILE"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

echo "Backhaul service started."
echo "Status:"
systemctl --no-pager status "$SERVICE_NAME" || true
