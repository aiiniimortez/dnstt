#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/root/backhaul-core"
BIN_URL="https://github.com/aiiniimortez/dnstt/raw/refs/heads/main/backhaul_premium.zip"
SH_URL="https://raw.githubusercontent.com/aiiniimortez/dnstt/refs/heads/main/backhaul_premium.sh"
BIN_ARCHIVE="./backhaul_premium.zip"
LOCAL_SH="./backhaul_premium.sh"
BIN_PATH="${BASE_DIR}/backhaul_premium"

DEFAULT_EDGE_IP="185.143.235.201"
DEFAULT_IRAN_IP="8.8.8.8"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

install_dependencies() {
  apt-get update -y
  apt-get install -y unzip jq wget iproute2
}

validate_ipv4() {
  local ip="$1"
  local re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
  if [[ ! "$ip" =~ $re ]]; then
    echo "Invalid IPv4 address: $ip" >&2
    exit 1
  fi

  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
  for octet in "$o1" "$o2" "$o3" "$o4"; do
    if (( octet < 0 || octet > 255 )); then
      echo "Invalid IPv4 address: $ip" >&2
      exit 1
    fi
  done
}

cleanup_old_services() {
  shopt -s nullglob
  for service_file in /etc/systemd/system/backhaul-*.service; do
    service_name="$(basename "$service_file")"
    systemctl stop "$service_name" >/dev/null 2>&1 || true
    systemctl disable "$service_name" >/dev/null 2>&1 || true
    rm -f "$service_file"
  done
  systemctl daemon-reload || true
}

prepare_directory() {
  mkdir -p "$BASE_DIR"
  rm -rf "${BASE_DIR:?}"/*
}

download_files() {
  wget -qO "$BIN_ARCHIVE" "$BIN_URL"
  unzip -o -q "$BIN_ARCHIVE"
  mv -f backhaul_premium.bin "$BIN_PATH"
  chmod +x "$BIN_PATH"

  wget -qO "$LOCAL_SH" "$SH_URL"
  chmod +x "$LOCAL_SH"
}

detect_server_info() {
  local route_line
  route_line="$(ip -4 route get 1.1.1.1 2>/dev/null | head -n1 || true)"

  SERVER_IP="$(awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' <<< "$route_line")"
  SERVER_IFACE="$(awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<< "$route_line")"

  if [[ -z "${SERVER_IP}" ]]; then
    SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi

  if [[ -z "${SERVER_IFACE}" ]]; then
    SERVER_IFACE="$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}' || true)"
  fi

  if [[ -z "${SERVER_IP}" || -z "${SERVER_IFACE}" ]]; then
    echo "Could not detect server IP or interface automatically." >&2
    exit 1
  fi
}

write_service_unit() {
  local service_name="$1"
  local description="$2"
  local toml_name="$3"

  cat > "/etc/systemd/system/${service_name}.service" <<EOF
[Unit]
Description=${description}
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${BASE_DIR}
ExecStart=${BIN_PATH} -c ${BASE_DIR}/${toml_name}
Restart=always
RestartSec=3
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

enable_and_start_service() {
  local service_name="$1"
  systemctl daemon-reload
  systemctl enable "$service_name"
  systemctl restart "$service_name"
}

create_ws_tunnel() {
  cat > "${BASE_DIR}/kharej80.toml" <<EOF
[dialer]
remote_addr = "${DOMAIN}:80"
edge_ip = "${EDGE_IP}"
dial_timeout = 10
retry_interval = 3

[transport]
type = "ws"
nodelay = true
keepalive_period = 40
connection_pool = 8
heartbeat_interval = 10
heartbeat_timeout = 25

[security]
token = "ghsshfefuh3ufh3"

[tuning]
auto_tuning = true
tuning_profile = "balanced"
workers = 0
channel_size = 4096
tcp_mss = 0
so_rcvbuf = 0
so_sndbuf = 0
buffer_profile = "balanced"
read_timeout = 120

[logging]
log_level = "info"
EOF

  write_service_unit \
    "backhaul-kharej80" \
    "Backhaul Kharej Port 80" \
    "kharej80.toml"

  enable_and_start_service "backhaul-kharej80"
}

create_ipip_tunnel() {
  cat > "${BASE_DIR}/kharej2021.toml" <<EOF
[transport]
type = "tun"
heartbeat_interval = 10
heartbeat_timeout = 25

[tun]
encapsulation = "ipx"
name = "backhaul2"
local_addr = "10.10.20.2/24"
remote_addr = "10.10.20.1/24"
health_port = 2021
mtu = 800

[ipx]
mode = "client"
profile = "ipip"
listen_ip = "${SERVER_IP}"
dst_ip = "${IRAN_IP}"
interface = "${SERVER_IFACE}"

[security]
enable_encryption = true
algorithm = "aes-256-gcm"
psk = "pN9m6m0tH3nE3V8xKZ6Lq5yYcW2K1S7QG9u4cF0A8M4="
kdf_iterations = 100000

[tuning]
auto_tuning = true
tuning_profile = "balanced"
workers = 0
channel_size = 10_000
so_sndbuf = 0
batch_size = 2048

[logging]
log_level = "info"
EOF

  write_service_unit \
    "backhaul-kharej2021" \
    "Backhaul Kharej Port 2021" \
    "kharej2021.toml"

  enable_and_start_service "backhaul-kharej2021"
}

create_gre_tunnel() {
  cat > "${BASE_DIR}/kharej3031.toml" <<EOF
[transport]
type = "tun"
heartbeat_interval = 10
heartbeat_timeout = 25

[tun]
encapsulation = "ipx"
name = "backhaul3"
local_addr = "10.10.30.2/24"
remote_addr = "10.10.30.1/24"
health_port = 3031
mtu = 800

[ipx]
mode = "client"
profile = "bip"
listen_ip = "${SERVER_IP}"
dst_ip = "${IRAN_IP}"
interface = "${SERVER_IFACE}"

[security]
enable_encryption = true
algorithm = "aes-256-gcm"
psk = "pN9m6m0tH3nE3V8xKZ6Lq5yYcW2K1S7QG9u4cF0A8M4="
kdf_iterations = 100000

[tuning]
auto_tuning = true
tuning_profile = "balanced"
workers = 0
channel_size = 10_000
so_sndbuf = 0
batch_size = 2048

[logging]
log_level = "info"
EOF

  write_service_unit \
    "backhaul-kharej3031" \
    "Backhaul Kharej Port 3031" \
    "kharej3031.toml"

  enable_and_start_service "backhaul-kharej3031"
}

create_bip_tunnel() {
  cat > "${BASE_DIR}/kharej4041.toml" <<EOF
[transport]
type = "tun"
heartbeat_interval = 10
heartbeat_timeout = 25

[tun]
encapsulation = "ipx"
name = "backhual4"
local_addr = "10.10.40.2/24"
remote_addr = "10.10.40.1/24"
health_port = 4041
mtu = 800

[ipx]
mode = "client"
profile = "gre"
listen_ip = "${SERVER_IP}"
dst_ip = "${IRAN_IP}"
interface = "${SERVER_IFACE}"

[security]
enable_encryption = true
algorithm = "aes-256-gcm"
psk = "pN9m6m0tH3nE3V8xKZ6Lq5yYcW2K1S7QG9u4cF0A8M4="
kdf_iterations = 100000

[tuning]
auto_tuning = true
tuning_profile = "balanced"
workers = 0
channel_size = 10_000
so_sndbuf = 0
batch_size = 2048

[logging]
log_level = "info"
EOF

  write_service_unit \
    "backhaul-kharej4041" \
    "Backhaul Kharej Port 4041" \
    "kharej4041.toml"

  enable_and_start_service "backhaul-kharej4041"
}

main() {
  require_root

  if [[ $# -lt 1 || $# -gt 3 ]]; then
    echo "Usage: $0 <domain> [edge_ip] [iran_ip]" >&2
    exit 1
  fi

  DOMAIN="$1"
  EDGE_IP="${2:-$DEFAULT_EDGE_IP}"
  IRAN_IP="${3:-$DEFAULT_IRAN_IP}"

  validate_ipv4 "$EDGE_IP"
  validate_ipv4 "$IRAN_IP"

  install_dependencies
  cleanup_old_services
  prepare_directory
  download_files
  detect_server_info

  create_ws_tunnel
  create_ipip_tunnel
  create_gre_tunnel
  create_bip_tunnel

  echo "Backhaul setup completed."
  echo "Domain: ${DOMAIN}"
  echo "Edge IP: ${EDGE_IP}"
  echo "Iran IP: ${IRAN_IP}"
  echo "Server IP: ${SERVER_IP}"
  echo "Server interface: ${SERVER_IFACE}"
}

main "$@"
