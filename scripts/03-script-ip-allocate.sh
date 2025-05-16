#!/bin/bash
# Exit on error
set -e

# API Endpoint for IP allocation
API_ENDPOINT="http://vlan-leader-service.kube-system.svc.cluster.local:8080/allocate"
SUBNET=$1

# Logging function
log() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $1"
    exit 1
}

# === Main Logic ===
if [ -z "$SUBNET" ]; then
    error "No subnet provided for IP allocation."
fi

log "Requesting IP from API at $API_ENDPOINT for Subnet: $SUBNET..."

# Execute the curl command and capture response and status code
RESPONSE=$(curl -s -w "%{http_code}" -o /tmp/response_body.txt -X POST $API_ENDPOINT \
    -H "Content-Type: application/json" \
    -d "{\"subnet\": \"$SUBNET\"}")
HTTP_CODE="${RESPONSE: -3}"
RESPONSE_BODY=$(cat /tmp/response_body.txt)

# Evaluate the response
if [ "$HTTP_CODE" == "200" ]; then
    ALLOCATED_IP=$(echo $RESPONSE_BODY | jq -r '.allocated_ip')
    log "Successfully allocated IP: $ALLOCATED_IP"
    echo $ALLOCATED_IP
else
    case $HTTP_CODE in
        404)
            error "API Endpoint not found. Service 'vlan-leader-service' may not be running in namespace 'kube-system'."
            ;;
        500)
            error "No IP addresses available in the provided subnet."
            ;;
        400)
            error "Bad request. The subnet format is incorrect."
            ;;
        000)
            error "Cannot reach the API. Possible DNS issue or service is down."
            ;;
        *)
            error "Unexpected error (HTTP $HTTP_CODE) from API: $RESPONSE_BODY"
            ;;
    esac
fi
