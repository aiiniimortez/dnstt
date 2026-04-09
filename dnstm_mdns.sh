#!/bin/bash
set -euo pipefail

DOMAINS_FILE="/root/domains.txt"
CSV_OUT="/root/dnstm_tunnels.csv"

DNSTM_DIR="/root/dnstm"
DNSTM_BIN="$DNSTM_DIR/dnstm"
DNSTM_REPO="https://github.com/retro1878/dnstm"
DNSTM_BRANCH="claude/add-master-dns-vpn-provider-4vRfK"

GO_REQUIRED_MIN="1.24.0"
GO_TARBALL_URL="https://go.dev/dl/go1.24.3.linux-amd64.tar.gz"
GO_TARBALL="/tmp/go1.24.3.linux-amd64.tar.gz"

TUNNEL_TRANSPORT="masterdnsvpn"
ROUTER_SERVICE="dnstm-dnsrouter.service"

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root."
  exit 1
fi

if [ ! -f "$DOMAINS_FILE" ]; then
  echo "File $DOMAINS_FILE not found. Please put domains inside it."
  exit 1
fi

version_ge() {
  # returns 0 if $1 >= $2
  [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

ensure_go() {
  local current_version=""

  if command -v go >/dev/null 2>&1; then
    current_version="$(go version | awk '{print $3}' | sed 's/^go//')"
  fi

  if [ -z "$current_version" ] || ! version_ge "$current_version" "$GO_REQUIRED_MIN"; then
    echo "=> Installing Go 1.24.3 ..."
    wget -q "$GO_TARBALL_URL" -O "$GO_TARBALL"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "$GO_TARBALL"
  else
    echo "=> Go $current_version is already >= $GO_REQUIRED_MIN"
  fi

  export PATH="/usr/local/go/bin:$PATH"
  hash go 2>/dev/null || true
  echo "=> $(go version)"
}

ensure_repo() {
  if [ ! -d "$DNSTM_DIR/.git" ]; then
    echo "=> Cloning dnstm repository ..."
    rm -rf "$DNSTM_DIR"
    git clone "$DNSTM_REPO" "$DNSTM_DIR"
  fi

  cd "$DNSTM_DIR"
}

ensure_binary() {
  if [ -x "$DNSTM_BIN" ]; then
    echo "=> dnstm binary already exists and is executable; skipping build."
    return
  fi

  echo "=> Building dnstm ..."
  git fetch origin
  git checkout -B "$DNSTM_BRANCH" "origin/$DNSTM_BRANCH"
  go build -o dnstm .
  chmod +x "$DNSTM_BIN"
}

is_dnstm_installed() {
  id dnstm >/dev/null 2>&1 || return 1
  systemctl cat dnstm-dnsrouter.service >/dev/null 2>&1 || return 1
  "$DNSTM_BIN" router status >/dev/null 2>&1 || return 1
  return 0
}

ensure_install() {
  if is_dnstm_installed; then
    echo "=> dnstm already installed; skipping install."
    return
  fi

  echo "=> Running dnstm install ..."
  "$DNSTM_BIN" install --mode multi --force
}

set_router_multi() {
  echo "=> Setting router mode to multi ..."
  "$DNSTM_BIN" router mode multi || true
  sleep 1
  systemctl enable "$ROUTER_SERVICE" || true
  sleep 1
  systemctl restart "$ROUTER_SERVICE" || true
}

sanitize_tunnel_name() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/\./-/g' \
    | sed 's/[^a-z0-9-]/-/g'
}

extract_encryption_key() {
  local file="$1"
  local key=""

  key="$(
    awk '
      /Encryption Key/ { found=1; next }
      found && NF {
        gsub(/^[ \t]+|[ \t]+$/, "", $0)
        print $0
        exit
      }
    ' "$file" || true
  )"

  if [ -z "$key" ]; then
    key="$(grep -Eo '[0-9a-fA-F]{32,}' "$file" | head -n1 || true)"
  fi

  printf '%s' "$key"
}

process_domain() {
  local domain="$1"
  local tunnel_name
  local output_file
  local enc_key

  tunnel_name="$(sanitize_tunnel_name "$domain")"
  echo "-> Creating tunnel for domain: $domain (tunnel name: $tunnel_name)"

  output_file="$(mktemp)"
  if ! "$DNSTM_BIN" tunnel add -t "$tunnel_name" --transport "$TUNNEL_TRANSPORT" --domain "$domain" &> "$output_file"; then
    echo "Warning: tunnel creation returned non-zero for $domain (continuing)."
  fi

  enc_key="$(extract_encryption_key "$output_file")"
  rm -f "$output_file"

  if [ -z "$enc_key" ]; then
    echo "Warning: Encryption key not found for $domain"
  fi

  printf '"%s","%s"\n' "$domain" "$enc_key" >> "$CSV_OUT"

  sleep 1
}

echo "=> Checking Go ..."
ensure_go

echo "=> Preparing project ..."
ensure_repo

echo "=> Checking build ..."
ensure_binary

echo "=> Installing dnstm ..."
ensure_install

echo "=> Setting router to multi mode ..."
set_router_multi

echo "domain,encryption_key" > "$CSV_OUT"

echo "=> Reading domains and creating tunnels ..."
while IFS= read -r line || [ -n "$line" ]; do
  domain="$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//')"

  if [ -z "$domain" ] || [[ "$domain" =~ ^# ]]; then
    continue
  fi

  process_domain "$domain"
done < "$DOMAINS_FILE"

echo "=> Waiting before final router restart ..."
sleep 1
systemctl enable "$ROUTER_SERVICE" || true
systemctl restart "$ROUTER_SERVICE" || true

echo
echo "=> CSV saved to: $CSV_OUT"
echo "=> CSV content:"
cat "$CSV_OUT"
