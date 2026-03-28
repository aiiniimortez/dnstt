#!/bin/bash

set -e

APP_DIR="/opt/cf_bot"
FILE_URL="https://raw.githubusercontent.com/aiiniimortez/dnstt/refs/heads/main/cf_bot.py"
SERVICE_FILE="/etc/systemd/system/cf_bot.service"

echo "Starting setup..."

# 1. Check directory
if [ ! -d "$APP_DIR" ]; then
    echo "Directory $APP_DIR does not exist. Creating..."
    mkdir -p "$APP_DIR"
else
    echo "Directory $APP_DIR already exists."
fi

# 2. Download file (replace if exists)
echo "Downloading latest bot file..."
curl -L "$FILE_URL" -o "$APP_DIR/cf_bot.py"

# 3. Check Python installation
if ! command -v python3 &> /dev/null; then
    echo "Python3 is not installed. Installing..."
    apt update && apt install -y python3
else
    echo "Python3 is already installed."
fi

# 4. Check venv module
if ! python3 -m venv --help &> /dev/null; then
    echo "python3-venv is not installed. Installing..."
    apt install -y python3-venv
else
    echo "python3-venv is available."
fi

# 5. Create virtual environment
if [ ! -d "$APP_DIR/venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv "$APP_DIR/venv"
else
    echo "Virtual environment already exists."
fi

# 6. Install dependencies
echo "Installing required Python packages..."
"$APP_DIR/venv/bin/pip" install --upgrade pip
"$APP_DIR/venv/bin/pip" install requests python-telegram-bot==20.5

# 7. Create systemd service
echo "Creating systemd service..."
cat > "$SERVICE_FILE" <<EOL
[Unit]
Description=Cloudflare Telegram Bot
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/cf_bot
ExecStart=/opt/cf_bot/venv/bin/python3 /opt/cf_bot/cf_bot.py
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOL

# 8. Reload daemon
echo "Reloading systemd daemon..."
systemctl daemon-reexec
systemctl daemon-reload

# 9. Enable and start service
echo "Enabling service..."
systemctl enable cf_bot.service

echo "Restarting service..."
systemctl restart cf_bot.service

echo "Checking service status..."
systemctl status cf_bot.service --no-pager

# 10. Final message
echo "--------------------------------------------------"
echo "Setup completed successfully!"
echo ""
echo "Now add your domains to the following file:"
echo "/opt/cf_bot/domains.txt"
echo ""
echo "Format:"
echo "1, \"domain1.ir\", \"api_key1\""
echo "2, \"domain2.ir\", \"api_key2\""
echo "--------------------------------------------------"
