# 03-script-ip-allocate.sh
# 
# This shell script handles IP address allocation by interacting with the VLAN
# Leader Manager's REST API. It requests an available IP from the specified subnet
# and logs the result.
# 
# -----------------------------------------------------
# 📝 Parameters:
# 
# 1️⃣ SUBNET              - The subnet from which IPs are allocated.
# 2️⃣ API_ENDPOINT        - The endpoint for IP allocation requests.
# 
# -----------------------------------------------------
# 🔄 Usage:
# 
# - This script is executed during VLAN manager initialization or scale-up events.
# - It calls the API to request an available IP address.
# - If successful, the IP is logged and returned.
# 
# -----------------------------------------------------
# 📌 Best Practices:
# 
# - Ensure the API is reachable before executing the script.
# - Monitor logs for successful IP allocation or errors.
# - Handle API timeouts and unexpected responses gracefully.
# 
# -----------------------------------------------------
# 🖋️ Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
# 
# © Linode-LKE-Private-Network | Developed by Sandip Gangdhar | 2025
#!/bin/bash
# Exit on error
set -e

# === Environment Variables ===
# API endpoint for IP allocation
API_ENDPOINT="http://vlan-leader-service.kube-system.svc.cluster.local:8080/allocate"

# Subnet is passed as the first argument
SUBNET=$1

# === Function to Log Events ===
# This function logs events with timestamps for better traceability
log() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $1"
    exit 1
}

log() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# === Main Logic ===
log "🔄 Starting IP Allocation Request..."

# === Validate the subnet is provided ===
# If the subnet is not passed as an argument, exit with an error
if [ -z "$SUBNET" ]; then
    error "No subnet provided for IP allocation."
fi
log "🌐 Subnet provided for allocation: $SUBNET"

log "Requesting IP from API at $API_ENDPOINT for Subnet: $SUBNET..."

# === Send IP Allocation Request ===
log "📡 Sending IP allocation request to API at $API_ENDPOINT..."
# Execute the curl command and capture response and status code
RESPONSE=$(curl -s -w "%{http_code}" -o /tmp/response_body.txt -X POST $API_ENDPOINT \
    -H "Content-Type: application/json" \
    -d "{\"subnet\": \"$SUBNET\"}")

# Extract HTTP status code and response body from the curl request
HTTP_CODE="${RESPONSE: -3}"
RESPONSE_BODY=$(cat /tmp/response_body.txt)

# Evaluate the response
if [ "$HTTP_CODE" == "200" ]; then
    # Parse the allocated IP from the JSON response
    ALLOCATED_IP=$(echo $RESPONSE_BODY | jq -r '.allocated_ip')
    log " ✅ Successfully allocated IP: $ALLOCATED_IP"
    echo $ALLOCATED_IP
else
    # Log the failure and exit with an error status
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
