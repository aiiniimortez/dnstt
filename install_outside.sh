#!/usr/bin/env bash

set -e

echo "=== DN Monitor Outside Installer ==="

# --- install dependencies ---

echo "Installing dependencies..."
apt update
apt install -y python3-pip python3-venv wget

# --- create directories ---

echo "Creating directories..."
mkdir -p /opt/dn_monitor
touch /etc/dn_monitor_env
chown root:root /etc/dn_monitor_env

cd /opt/dn_monitor

# --- create venv ---

echo "Creating Python virtualenv..."
python3 -m venv venv

# activate venv

source venv/bin/activate

# install python libs

echo "Installing Python packages..."
pip install --upgrade pip
pip install flask python-dotenv

# --- download python server ---

echo "Downloading outside_server.py..."
wget -O /opt/dn_monitor/outside_server.py https://raw.githubusercontent.com/aiiniimortez/dnstt/refs/heads/main/outside_server.py

chmod +x /opt/dn_monitor/outside_server.py

# --- create systemd service ---

echo "Creating systemd service..."

cat <<EOF > /etc/systemd/system/dn-monitor-outside.service
[Unit]
Description=DN Monitor Outside API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/dn_monitor

ExecStart=/opt/dn_monitor/venv/bin/python /opt/dn_monitor/outside_server.py

Restart=always
RestartSec=5

NoNewPrivileges=true
PrivateTmp=true

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo
echo "=== Enter UUIDs of Iran servers ==="
echo "Type 'exit' when finished"
echo

while true; do
read -p "Enter UUID: " uuid

```
if [[ "$uuid" == "exit" ]]; then
    break
fi

if [[ -n "$uuid" ]]; then
    echo "$uuid" >> /etc/dn_monitor_env
    echo "UUID added."
fi
```

done

echo
echo "Reloading systemd..."

systemctl daemon-reload
systemctl enable dn-monitor-outside
systemctl start dn-monitor-outside

echo
echo "===================================="
echo "Installation completed!"
echo
echo "Service status:"
systemctl status dn-monitor-outside --no-pager
echo "===================================="
