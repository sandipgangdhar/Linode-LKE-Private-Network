#!/bin/bash
# Exit on error
set -e

# API Endpoint for IP release
API_ENDPOINT="http://vlan-leader-service.kube-system.svc.cluster.local:8080/release"
IP_ADDRESS=$1

# Logging function
log() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $1"
    exit 1
}

# === Main Logic ===
if [ -z "$IP_ADDRESS" ]; then
    error "No IP address provided for release."
fi

log "Requesting IP release from API at $API_ENDPOINT for IP: $IP_ADDRESS..."

# Execute the curl command and capture response and status code
RESPONSE=$(curl -s -w "%{http_code}" -o /tmp/response_body.txt -X POST $API_ENDPOINT -H "Content-Type: application/json" -d "{\"ip_address\": \"$IP_ADDRESS\"}")
HTTP_CODE="${RESPONSE: -3}"
RESPONSE_BODY=$(cat /tmp/response_body.txt)

# Evaluate the response
if [ "$HTTP_CODE" == "200" ]; then
    log "Successfully released IP: $IP_ADDRESS"
    echo $IP_ADDRESS
else
    case $HTTP_CODE in
        404)
            error "IP address $IP_ADDRESS not found in the allocation list."
            ;;
        400)
            error "Bad request. Possibly malformed JSON or missing IP address."
            ;;
        000)
            error "Cannot reach the API. Possible DNS issue or service is down."
            ;;
        *)
            error "Unexpected error (HTTP $HTTP_CODE) from API: $RESPONSE_BODY"
            ;;
    esac
fi
