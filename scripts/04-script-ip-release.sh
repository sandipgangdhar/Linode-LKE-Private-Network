# 04-script-ip-release.sh
# 
# This shell script handles IP address release by interacting with the VLAN
# Leader Manager's REST API. It releases an assigned IP back to the pool and
# logs the result.
# 
# -----------------------------------------------------
# 📝 Parameters:
# 
# 1️⃣ IP_ADDRESS          - The IP address to be released back to the pool.
# 2️⃣ API_ENDPOINT        - The endpoint for IP release requests.
# 
# -----------------------------------------------------
# 🔄 Usage:
# 
# - This script is executed when an IP address is no longer required.
# - It calls the API to release the IP address from the allocation pool.
# - If successful, the IP is removed from active usage.
# 
# -----------------------------------------------------
# 📌 Best Practices:
# 
# - Ensure the API is reachable before executing the script.
# - Monitor logs for successful IP release or errors.
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
# API endpoint for IP release
API_ENDPOINT="http://vlan-leader-service.kube-system.svc.cluster.local:8080/release"

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

# === Main Logic ===
log "🔄 Starting IP Release Request..."

# === Validate the IP Address is provided ===
# If the IP address is not passed as an argument, exit with an error
if [ -z "$IP_ADDRESS" ]; then
    error "No IP address provided for release."
fi

log "🌐 IP Address to be released: $IP_ADDRESS"

# === Send IP Release Request ===
log "📡 Requesting IP release from API at $API_ENDPOINT for IP: $IP_ADDRESS..."

# Execute the curl command to POST to the VLAN Leader API
# -s for silent, -w for status code, -o to write body to a file
RESPONSE=$(curl -s -w "%{http_code}" -o /tmp/response_body.txt -X POST $API_ENDPOINT -H "Content-Type: application/json" -d "{\"ip_address\": \"$IP_ADDRESS\"}")

# === Extract Response Details ===
# Get HTTP status code and body from the curl request
HTTP_CODE="${RESPONSE: -3}"
RESPONSE_BODY=$(cat /tmp/response_body.txt)

# === Check the API Response ===
if [ "$HTTP_CODE" == "200" ]; then
    # Log the successful release of the IP address
    log "✅ Successfully released IP: $IP_ADDRESS"
    echo $IP_ADDRESS
else
    case $HTTP_CODE in
         # Log the failure and exit with an error status
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
