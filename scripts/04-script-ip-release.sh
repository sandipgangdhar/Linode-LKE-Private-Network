#!/bin/bash
# 04-script-ip-release.sh
#
# NOTE: the shebang above must stay on line 1 - see the matching note at
# the top of scripts/03-script-ip-allocate.sh for why (this script had the
# identical bug: shebang buried after the comment header, silently falling
# back to /bin/sh - dash - on a bare-path invocation, breaking `==` inside
# `[ ]`). This script isn't currently invoked anywhere in the deployed
# system (see the "No EXIT-trap IP release here, deliberately" comment in
# 02-script-vlan-attach.sh), but fixing it to match 03's now-correct
# shebang placement costs nothing and avoids the same trap if it's ever
# wired back in.
#
# This shell script handles IP address release by interacting with the VLAN
# Leader Manager's REST API. It releases an assigned IP back to the pool and
# logs the result.
# 
# -----------------------------------------------------
# Parameters:
# 
# 1. IP_ADDRESS          - The IP address to be released back to the pool.
# 2. API_ENDPOINT        - The endpoint for IP release requests.
# 
# -----------------------------------------------------
# Usage:
# 
# - This script is executed when an IP address is no longer required.
# - It calls the API to release the IP address from the allocation pool.
# - If successful, the IP is removed from active usage.
# 
# -----------------------------------------------------
# Best Practices:
# 
# - Ensure the API is reachable before executing the script.
# - Monitor logs for successful IP release or errors.
# - Handle API timeouts and unexpected responses gracefully.
# 
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
# 
# © Linode-LKE-Private-Network | Developed by Sandip Gangdhar | 2025
# Exit on error
set -e

# === Environment Variables ===
# API endpoint for IP release
API_ENDPOINT="http://vlan-ip-controller-service.kube-system.svc.cluster.local:8080/release"

# IP Address is passed as the first argument
IP_ADDRESS=$1

# === Function to Log Events ===
# This function logs events with timestamps for better traceability
log() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $1"
    exit 1
}

# === Retry tuning (see the matching comment in 03-script-ip-allocate.sh) ===
MAX_RETRIES="${IP_RELEASE_MAX_RETRIES:-3}"
BACKOFF_BASE_SECONDS="${IP_RELEASE_BACKOFF_BASE_SECONDS:-2}"

# === Main Logic ===
log "Starting IP release request..."

# === Validate the IP Address is provided ===
# If the IP address is not passed as an argument, exit with an error
if [ -z "$IP_ADDRESS" ]; then
    error "No IP address provided for release."
fi

log "IP address to be released: $IP_ADDRESS"

attempt=1
while true; do
    log "Requesting IP release from API at $API_ENDPOINT for IP: $IP_ADDRESS (attempt $attempt/$MAX_RETRIES)..."

    # `|| true`: see the matching comment in 03-script-ip-allocate.sh - a
    # hard connection failure makes curl itself exit non-zero regardless of
    # the "000" it writes to HTTP_CODE, which would otherwise abort this
    # `set -e` script before the retry loop below ever ran.
    RESPONSE=$(curl -s -w "%{http_code}" -o /tmp/response_body.txt -X POST "$API_ENDPOINT" -H "Content-Type: application/json" -d "{\"ip_address\": \"$IP_ADDRESS\"}") || true

    HTTP_CODE="${RESPONSE: -3}"
    RESPONSE_BODY=$(cat /tmp/response_body.txt 2>/dev/null || echo "")

    if [ "$HTTP_CODE" == "200" ]; then
        log "Successfully released IP: $IP_ADDRESS"
        echo "$IP_ADDRESS"
        exit 0
    fi

    # Not retryable - wrong by construction, a fresh attempt fails the same way.
    case "$HTTP_CODE" in
        404)
            error "IP address $IP_ADDRESS not found in the allocation list."
            ;;
        400)
            error "Bad request. Possibly malformed JSON or missing IP address."
            ;;
    esac

    if [ "$attempt" -ge "$MAX_RETRIES" ]; then
        case "$HTTP_CODE" in
            000)
                error "Cannot reach the API after $MAX_RETRIES attempts. Possible DNS issue or the service is down."
                ;;
            *)
                error "Unexpected error (HTTP $HTTP_CODE) from API after $MAX_RETRIES attempts: $RESPONSE_BODY"
                ;;
        esac
    fi

    wait_time=$((BACKOFF_BASE_SECONDS ** attempt))
    log "Release request failed (HTTP $HTTP_CODE), retrying in ${wait_time}s..."
    sleep "$wait_time"
    attempt=$((attempt + 1))
done
