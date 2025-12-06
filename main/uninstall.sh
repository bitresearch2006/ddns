#!/bin/bash
# ==============================================================
# Uninstaller for Cloudflare Dynamic DNS Updater
# Reverses changes made by install.sh
# ==============================================================

# Define paths (Must match install.sh)
SCRIPT_PATH="/usr/local/bin/UpdateCloudflareDNS.sh"
SERVICE_PATH="/etc/systemd/system/cloudflare-ddns.service"
CONFIG_PATH="/etc/cloudflare-ddns.env"
LOG_PATH="/var/log/cloudflare-ddns.log"
LOGROTATE_PATH="/etc/logrotate.d/cloudflare-ddns"

echo "🗑️  Uninstalling Cloudflare DDNS Updater..."

# 1. Stop and Disable Service
if systemctl is-active --quiet cloudflare-ddns.service; then
    echo "🛑 Stopping service..."
    sudo systemctl stop cloudflare-ddns.service
fi

if systemctl is-enabled --quiet cloudflare-ddns.service; then
    echo "🔌 Disabling service..."
    sudo systemctl disable cloudflare-ddns.service
fi

# 2. Remove System Files
echo "🧹 Removing system files..."

if [ -f "$SCRIPT_PATH" ]; then
    sudo rm "$SCRIPT_PATH"
    echo "   - Removed script: $SCRIPT_PATH"
fi

if [ -f "$SERVICE_PATH" ]; then
    sudo rm "$SERVICE_PATH"
    echo "   - Removed service file: $SERVICE_PATH"
fi

if [ -f "$LOGROTATE_PATH" ]; then
    sudo rm "$LOGROTATE_PATH"
    echo "   - Removed logrotate config: $LOGROTATE_PATH"
fi

# 3. Reload Systemd
echo "🔄 Reloading systemd daemon..."
sudo systemctl daemon-reload
sudo systemctl reset-failed

# 4. Optional: Remove Config (User Prompt)
if [ -f "$CONFIG_PATH" ]; then
    echo ""
    echo "⚠️  Found configuration file with API keys at: $CONFIG_PATH"
    read -p "❓ Do you want to DELETE this config file? (y/N): " confirm_conf
    if [[ "$confirm_conf" =~ ^[Yy]$ ]]; then
        sudo rm "$CONFIG_PATH"
        echo "   - Removed config file."
    else
        echo "   - Kept config file."
    fi
fi

# 5. Optional: Remove Logs (User Prompt)
# Check for main log or rotated logs
if ls $LOG_PATH* 1> /dev/null 2>&1; then
    echo ""
    echo "⚠️  Found log files at: $LOG_PATH"
    read -p "❓ Do you want to DELETE the log files? (y/N): " confirm_log
    if [[ "$confirm_log" =~ ^[Yy]$ ]]; then
        sudo rm $LOG_PATH*
        echo "   - Removed log files."
    else
        echo "   - Kept log files."
    fi
fi

echo ""
echo "✅ Uninstallation complete."