#!/usr/bin/env bash
#
# Cloudflare Dynamic DNS Updater
# Requires env vars:
#   CF_API_TOKEN      - Cloudflare API token (Zone DNS:Edit for bitone.in)
#   CF_ZONE_ID        - Cloudflare Zone ID for bitone.in
#   CF_DNS_RECORD_ID  - DNS record ID for the A record to update
#
# Optional env vars:
#   CF_DNS_NAME       - DNS name, e.g. "bitone.in" or "home.bitone.in" (default: "bitone.in")
#   CF_TTL            - TTL in seconds (default: 600)
#   CF_PROXIED        - "true" or "false" (default: "false")

# Load env vars from config file if present
ENV_FILE="/etc/cloudflare-ddns.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi

set -euo pipefail

########################################
#          CONFIGURATION               #
########################################

CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
CF_DNS_RECORD_ID="${CF_DNS_RECORD_ID:-}"

CF_DNS_NAME="${CF_DNS_NAME:-bitone.in}"
TTL="${CF_TTL:-600}"
CF_PROXIED="${CF_PROXIED:-false}"

# Check interval
CHECK_INTERVAL_SECONDS=300  # how often to check the IP (in seconds)

# Log file
LOG_FILE="/var/log/cloudflare-ddns.log"

# For logging only
DOMAIN="$CF_DNS_NAME"

########################################
#          HELPER FUNCTIONS            #
########################################

log() {
    # Log with fresh timestamp each time
    local now
    now=$(date +"%Y-%m-%d %H:%M:%S")
    echo "$now $1" >> "$LOG_FILE"
}

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' not found. Please install it." >&2
        exit 1
    fi
}

validate_ip() {
    # Basic IPv4 validation
    local ip="$1"

    # Simple regex check
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi

    # Each octet <= 255
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    for octet in "$o1" "$o2" "$o3" "$o4"; do
        if (( octet < 0 || octet > 255 )); then
            return 1
        fi
    done

    return 0
}

get_public_ip() {
    # List of reliable IP echo services
    local urls=(
        "https://api.ipify.org"
        "https://ifconfig.me/ip"
        "https://icanhazip.com"
        "https://checkip.amazonaws.com"
    )

    for url in "${urls[@]}"; do
        # Try fetching IP with 5s timeout
        local ip
        ip=$(curl -4 -s --max-time 5 "$url" || true)
        
        # Trim whitespace
        ip=$(echo "$ip" | xargs)

        if validate_ip "$ip"; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

########################################
#          INITIAL CHECKS              #
########################################

# Required env vars
if [[ -z "$CF_API_TOKEN" || -z "$CF_ZONE_ID" || -z "$CF_DNS_RECORD_ID" ]]; then
    echo "ERROR: CF_API_TOKEN, CF_ZONE_ID and CF_DNS_RECORD_ID must be set as environment variables." >&2
    exit 1
fi

# Check required tools
require_command curl
require_command jq

# Ensure we can write log file
if ! touch "$LOG_FILE" 2>/dev/null; then
    echo "ERROR: Cannot write to log file: $LOG_FILE" >&2
    exit 1
fi

log "===== Starting Cloudflare DDNS updater for ${DOMAIN} ====="

# Cache current IP to avoid unnecessary API calls
CURRENT_IP=""

CF_API_BASE="https://api.cloudflare.com/client/v4"

########################################
#               MAIN LOOP              #
########################################

while true; do
# 1) Fetch current public IP using the ROBUST function
    if ! NEW_IP=$(get_public_ip); then
        log "ERROR: Could not determine public IP from any provider."
        sleep 60 # Retry sooner if internet is down
        continue
    fi

    if [[ -z "${NEW_IP}" ]]; then
        log "ERROR: Could not determine current public IP (empty response)."
        sleep "$CHECK_INTERVAL_SECONDS"
        continue
    fi

    if ! validate_ip "$NEW_IP"; then
        log "ERROR: Received invalid IP address from ipify: ${NEW_IP}"
        sleep "$CHECK_INTERVAL_SECONDS"
        continue
    fi

    # If our cached IP matches, no need to hit Cloudflare
    if [[ "$NEW_IP" == "$CURRENT_IP" ]]; then
        log "INFO: Public IP unchanged (${NEW_IP}), no update required."
        sleep "$CHECK_INTERVAL_SECONDS"
        continue
    fi

    # 2) Get current IP from Cloudflare for this record
    log "INFO: Checking Cloudflare DNS for ${DOMAIN} (current public IP: ${NEW_IP})"

    CF_GET_RESPONSE=$(curl -sS -m 15 \
        -w "HTTPSTATUS:%{http_code}" \
        -X GET "${CF_API_BASE}/zones/${CF_ZONE_ID}/dns_records/${CF_DNS_RECORD_ID}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" || true)

    GET_BODY="${CF_GET_RESPONSE%HTTPSTATUS:*}"
    GET_STATUS="${CF_GET_RESPONSE##*HTTPSTATUS:}"

    if [[ -z "$GET_STATUS" || "$GET_STATUS" == "$CF_GET_RESPONSE" ]]; then
        log "ERROR: Failed to contact Cloudflare API (no HTTP status). Raw response: ${CF_GET_RESPONSE}"
        sleep "$CHECK_INTERVAL_SECONDS"
        continue
    fi

    if [[ "$GET_STATUS" != "200" ]]; then
        log "ERROR: Cloudflare GET returned HTTP $GET_STATUS. Body: ${GET_BODY}"
        sleep "$CHECK_INTERVAL_SECONDS"
        continue
    fi

    CF_SUCCESS=$(echo "$GET_BODY" | jq -r '.success // false' 2>/dev/null || echo "false")
    if [[ "$CF_SUCCESS" != "true" ]]; then
        ERRORS=$(echo "$GET_BODY" | jq -c '.errors // []' 2>/dev/null || echo "[]")
        log "ERROR: Cloudflare GET success=false. Errors: ${ERRORS}"
        sleep "$CHECK_INTERVAL_SECONDS"
        continue
    fi

    CF_IP=$(echo "$GET_BODY" | jq -r '.result.content // empty' 2>/dev/null || echo "")

    if [[ -z "$CF_IP" ]]; then
        log "INFO: No existing A record content found. Treating as 0.0.0.0"
        CF_IP="0.0.0.0"
    fi

    if ! validate_ip "$CF_IP"; then
        log "WARN: Existing Cloudflare IP is invalid (${CF_IP}). Proceeding with update."
    fi

    if [[ "$CF_IP" == "$NEW_IP" ]]; then
        log "INFO: Cloudflare already has IP ${CF_IP}. Updating local cache and skipping PUT."
        CURRENT_IP="$NEW_IP"
        sleep "$CHECK_INTERVAL_SECONDS"
        continue
    fi

    # 3) Update Cloudflare record
    log "INFO: Updating Cloudflare A record for ${DOMAIN} from ${CF_IP} to ${NEW_IP}"

    # Build JSON payload using jq to ensure proper boolean for proxied
    JSON_PAYLOAD=$(jq -n \
        --arg type "A" \
        --arg name "$CF_DNS_NAME" \
        --arg content "$NEW_IP" \
        --argjson ttl "$TTL" \
        --argjson proxied "$([[ "$CF_PROXIED" == "true" ]] && echo true || echo false)" \
        '{type:$type, name:$name, content:$content, ttl:$ttl, proxied:$proxied}')

    CF_UPDATE_RESPONSE=$(curl -sS -m 15 \
        -w "HTTPSTATUS:%{http_code}" \
        -X PUT "${CF_API_BASE}/zones/${CF_ZONE_ID}/dns_records/${CF_DNS_RECORD_ID}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$JSON_PAYLOAD" || true)

    UPDATE_BODY="${CF_UPDATE_RESPONSE%HTTPSTATUS:*}"
    UPDATE_STATUS="${CF_UPDATE_RESPONSE##*HTTPSTATUS:}"

    if [[ -z "$UPDATE_STATUS" || "$UPDATE_STATUS" == "$CF_UPDATE_RESPONSE" ]]; then
        log "ERROR: Failed to update Cloudflare (no HTTP status). Raw response: ${CF_UPDATE_RESPONSE}"
        sleep "$CHECK_INTERVAL_SECONDS"
        continue
    fi

    if [[ "$UPDATE_STATUS" != "200" ]]; then
        log "ERROR: Cloudflare PUT returned HTTP ${UPDATE_STATUS}. Body: ${UPDATE_BODY}"
        sleep "$CHECK_INTERVAL_SECONDS"
        continue
    fi

    CF_UPDATE_SUCCESS=$(echo "$UPDATE_BODY" | jq -r '.success // false' 2>/dev/null || echo "false")
    if [[ "$CF_UPDATE_SUCCESS" == "true" ]]; then
        log "SUCCESS: Updated Cloudflare A record for ${DOMAIN} to ${NEW_IP}"
        CURRENT_IP="$NEW_IP"
    else
        ERRORS=$(echo "$UPDATE_BODY" | jq -c '.errors // []' 2>/dev/null || echo "[]")
        log "ERROR: Cloudflare update success=false. Errors: ${ERRORS}"
    fi

    # 4) Sleep before next iteration
    sleep "$CHECK_INTERVAL_SECONDS"
done

