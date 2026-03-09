#!/bin/bash
set -euo pipefail

DOMAINS_FILE="/root/domains.txt"
CSV_OUT="/root/dnstm_tunnels.csv"
TMP_INSTALL="/tmp/dnstm_install.sh"
USER_PREFIX="user_ssh"
USER_SHELL="/bin/bash"
TUNNEL_TRANSPORT="dnstt"
TUNNEL_BACKEND="ssh"
MTU=800

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root."
  exit 1
fi

if [ ! -f "$DOMAINS_FILE" ]; then
  echo "File $DOMAINS_FILE not found. Please make sure the domains are inside it."
  exit 1
fi

read -s -p "Enter password for all SSH users (will not echo): " PASSWORD
echo
read -p "Starting user number (default 1): " STARTNUM_IN
STARTNUM=${STARTNUM_IN:-1}

echo "=> Downloading dnstm installation script ..."
curl -sSL https://raw.githubusercontent.com/net2share/dnstm/main/install.sh -o "$TMP_INSTALL"
chmod +x "$TMP_INSTALL"

echo "=> Running dnstm installer and sending 'y' to the installer..."
# Some scripts read from stdin for confirmation; this sends y automatically
printf 'y\n' | bash "$TMP_INSTALL"

echo "=> Setting router mode to multi..."
dnstm router mode multi || true
systemctl enable dnstm-dnsrouter.service || true
systemctl restart dnstm-dnsrouter.service || true

# Preparing CSV
echo "domain,public_key,ssh_user" > "$CSV_OUT"

current=$STARTNUM
process_domain() {
  local domain="$1"
  # Generate tunnel name: lowercase, '.' -> '-', and replace non alphanumeric characters with '-'
  local tunnel=$(echo "$domain" | tr '[:upper:]' '[:lower:]' | sed 's/\./-/g' | sed 's/[^a-z0-9-]/-/g')

  echo "-> Creating tunnel for domain: $domain (tunnel name: $tunnel)"

  # Run command and capture output (stdout+stderr)
  OUTFILE=$(mktemp)
  if ! sudo dnstm tunnel add -t "$tunnel" --transport "$TUNNEL_TRANSPORT" --backend "$TUNNEL_BACKEND" --domain "$domain" --mtu "$MTU" &> "$OUTFILE"; then
    echo "Warning: dnstm tunnel add reported non-zero exit for $domain (see $OUTFILE). Continuing..."
  fi

  # Try extracting Public Key: line containing "Public Key" then the next line
  PUBKEY=$(awk '/Public Key/{getline; gsub(/^[ \t]+|[ \t]+$/,""); print $1; exit}' "$OUTFILE" || true)

  # Some outputs may contain "ℹ Public Key:" or have no label; try detecting a hex string
  if [ -z "$PUBKEY" ]; then
    # Find the first line containing a 20+ character hex string
    PUBKEY=$(awk '/[0-9a-fA-F]{20,}/ { gsub(/^[ \t]+|[ \t]+$/,""); print $1; exit }' "$OUTFILE" || true)
  fi

  rm -f "$OUTFILE"

  # Save to CSV (public key may be empty)
  echo "\"$domain\",\"$PUBKEY\",\"${USER_PREFIX}${current}\"" >> "$CSV_OUT"
}

echo "=> Reading domains and creating tunnels..."
# Read domains; ignore empty lines or lines starting with #
while IFS= read -r line || [ -n "$line" ]; do
  domain=$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//')
  # skip empty or commented lines
  if [ -z "$domain" ] || [[ "$domain" =~ ^# ]]; then
    continue
  fi

  process_domain "$domain"
  # Create one user per domain
  username="${USER_PREFIX}${current}"
  if id "$username" &>/dev/null; then
    echo "User $username already exists — skipping useradd."
  else
    echo "Creating user $username ..."
    useradd -m -s "$USER_SHELL" "$username"
    # Create .ssh directory and set permissions
    mkdir -p "/home/$username/.ssh"
    chmod 700 "/home/$username/.ssh"
    chown -R "$username:$username" "/home/$username"
    # Set password non-interactively
    echo "${username}:${PASSWORD}" | chpasswd
  fi

  current=$((current + 1))
done < "$DOMAINS_FILE"

echo "=> All tunnels have been added. Restarting router again..."
systemctl enable dnstm-dnsrouter.service || true
systemctl restart dnstm-dnsrouter.service || true

echo
echo "Done. CSV output saved to: $CSV_OUT"
echo "CSV format: domain,public_key,ssh_user"
