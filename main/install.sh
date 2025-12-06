#!/bin/bash
# ==============================================================
# Simple installer for Cloudflare Dynamic DNS Updater service
# Moves script and service file to proper system directories
# ==============================================================

set -e  # Exit on first error

# File locations (source in current directory)
SCRIPT_SRC="./UpdateCloudflareDNS.sh"
SERVICE_SRC="./cloudflare-ddns.service"

# Destination paths
SCRIPT_DEST="/usr/local/bin/UpdateCloudflareDNS.sh"
SERVICE_DEST="/etc/systemd/system/cloudflare-ddns.service"

echo "🚀 Installing Cloudflare DDNS updater..."

# 1. Move the main script
if [ -f "$SCRIPT_SRC" ]; then
    sudo mv "$SCRIPT_SRC" "$SCRIPT_DEST"
    sudo chmod 700 "$SCRIPT_DEST"
    echo "✅ Moved script to $SCRIPT_DEST"
else
    echo "❌ ERROR: $SCRIPT_SRC not found!"
    exit 1
fi

# 2. Move the service file
if [ -f "$SERVICE_SRC" ]; then
    sudo mv "$SERVICE_SRC" "$SERVICE_DEST"
    sudo chmod 644 "$SERVICE_DEST"
    echo "✅ Moved service file to $SERVICE_DEST"
else
    echo "❌ ERROR: $SERVICE_SRC not found!"
    exit 1
fi

# 2. Create Config Template (CRITICAL FIX)
if [ ! -f "$CONFIG_DEST" ]; then
    echo "⚠️  Config file not found. Creating template at $CONFIG_DEST..."
    exit 1
else
    echo "ℹ️  Config file already exists. Skipping creation."
fi

# 3. Reload systemd to recognize the new service
sudo systemctl daemon-reload

# 4. Enable and start the service
sudo systemctl enable cloudflare-ddns.service
sudo systemctl restart cloudflare-ddns.service

# 5. Check status
sudo systemctl status cloudflare-ddns.service --no-pager

echo "🎯 Installation complete!"
echo "View logs anytime with:  sudo journalctl -u cloudflare-ddns.service -f"
