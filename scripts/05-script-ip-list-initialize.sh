# 05-script-ip-list-initialize.sh
# 
# This shell script initializes the IP list for the VLAN Manager in Linode LKE.
# It scans the provided subnet range, generates all usable IP addresses, and
# stores them in a list that can be used for VLAN IP allocation.
# 
# -----------------------------------------------------
# 📝 Parameters:
# 
# 1️⃣ SUBNET               - The subnet from which IPs are initialized.
# 2️⃣ IP_FILE_PATH         - The file where the initialized IP list is stored.
# 
# -----------------------------------------------------
# 🔄 Usage:
# 
# - This script is executed during the initialization of VLAN Manager.
# - It parses the subnet and generates all usable IP addresses.
# - Reserved IPs (first, second, and last) are skipped.
# 
# -----------------------------------------------------
# 📌 Best Practices:
# 
# - Ensure the IP file path is writable before execution.
# - Monitor logs for any subnet parsing or IP conflicts.
# - Handle edge cases where the IP file already has data.
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

# --- Define Color Codes ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

LINODE_TOKEN="${LINODE_TOKEN}"
#LINODE_TOKEN=`grep token /root/.linode-cli/linode-cli | awk -F'= ' {'print $2'}`
OUTPUT_FILE="/tmp/vlan-ip-list.txt"
PAGE_SIZE=100
CURRENT_PAGE=1
TOTAL_PAGES=1
MAX_RETRIES=3
BACKOFF_BASE=2
INITIAL_JOBS=5
MAX_JOBS=20

# === Environment Variables ===
# File path for IP list storage
IP_FILE_PATH=$OUTPUT_FILE

# Subnet is passed as the first argument
SUBNET=$1
REGION=$2

# === Function to Log Events ===
# This function logs events with timestamps for better traceability
log() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# === Validate Subnet is Provided ===
# If the subnet is not passed as an argument, exit with an error
log "[DEBUG] Script received SUBNET=$SUBNET REGION=$REGION"

if [ -z "$SUBNET" ]; then
    log "[ERROR] No subnet provided for initialization."
    exit 1
fi

# === Validate if Region is Provided ===
# If the region is not passed as an argument, exit with an error
if [ -z "$REGION" ]; then
    log "[ERROR] No REGION provided for initialization."
    exit 1
fi

log "🔄 Starting IP List Initialization..."

log "🌐 Subnet provided for initialization: $SUBNET"

# --- Retry Logic Wrapper with Intelligent Backoff and 404 Handling ---
retry_curl() {
    local URL=$1
    local OUTPUT=$2
    local RETRY_COUNT=0
    local BACKOFF=1
    local SUCCESS=false

    while [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; do
        echo -e "${BLUE}🌐 Attempting API call: $URL (Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)${NC}"
        
        START_TIME=$(date +%s)  # Start timer

        if [[ "$URL" == *"/linode/instances/"*"/configs" ]]; then
            HTTP_CODE=$(curl -s -w "%{http_code}" -H "Authorization: Bearer $LINODE_TOKEN" \
                        "$URL" -o "$OUTPUT")
        else
            HTTP_CODE=$(curl -s -w "%{http_code}" -H "Authorization: Bearer $LINODE_TOKEN" \
                        -H 'X-Filter: {"region": "'$REGION'"}' \
                        "$URL" -o "$OUTPUT")
        fi

        END_TIME=$(date +%s)    # End timer
        DURATION=$((END_TIME - START_TIME))
        echo "$URL | $DURATION ms" >> latency-log.txt

        case "$HTTP_CODE" in
            200)
                if [ -s "$OUTPUT" ]; then
                    SUCCESS=true
                    echo -e "${GREEN}✅ API call successful ($DURATION ms): $URL${NC}"
                    break
                fi
                ;;
            404)
                echo -e "${RED}❌ [404] Resource not found: $URL${NC}" | tee -a error-log.txt
                echo -e "${YELLOW}   ➡️  Skipping further retries for this resource.${NC}"
                return 1
                ;;
            429)
                echo -e "${YELLOW}⚠️ Rate limit hit. Backing off for $BACKOFF seconds...${NC}"
                sleep "$BACKOFF"
                BACKOFF=$((BACKOFF * BACKOFF_BASE))
                ;;
            *)
                echo -e "${RED}⚠️ API call failed with HTTP Code $HTTP_CODE, retrying in $BACKOFF seconds...${NC}"
                sleep "$BACKOFF"
                BACKOFF=$((BACKOFF * BACKOFF_BASE))
                ;;
        esac

        ((RETRY_COUNT++))
    done

    if [ "$SUCCESS" = false ] && [ "$HTTP_CODE" != "404" ]; then
        echo -e "${RED}❌ API call failed after $MAX_RETRIES attempts: $URL${NC}" | tee -a error-log.txt
    fi
}

# --- Step 1: Paginated Fetch for All Linode IDs in the region with X-Filter ---
echo -e "${BLUE}🌐 Fetching Linode IDs in region $REGION with Pagination...${NC}"
while [ "$CURRENT_PAGE" -le "$TOTAL_PAGES" ]; do
    echo -e "${BLUE}   ➡️  Fetching page $CURRENT_PAGE of $TOTAL_PAGES${NC}"
    
    URL="https://api.linode.com/v4/linode/instances?page=$CURRENT_PAGE&page_size=$PAGE_SIZE"
    TEMP_RESPONSE=$(mktemp)
    
    # Fetch paginated data with retry logic
    retry_curl "$URL" "$TEMP_RESPONSE"
    
    # Fetch Linode IDs and append to file
    cat "$TEMP_RESPONSE" | jq -r '.data[] | .id' >> linodes.txt
    
    # Get pagination info
    TOTAL_PAGES=$(cat "$TEMP_RESPONSE" | jq -r '.pages')
    CURRENT_PAGE=$((CURRENT_PAGE + 1))
    rm -f "$TEMP_RESPONSE"
done

# --- Step 2: Count the number of Linode IDs and adjust MAX_JOBS ---
TOTAL_LINODES=$(wc -l < linodes.txt)
if [ "$TOTAL_LINODES" -lt "$INITIAL_JOBS" ]; then
    MAX_JOBS="$TOTAL_LINODES"
else
    # --- Adjust parallel jobs based on latency ---
    AVG_LATENCY=$(awk '{sum+=$3} END {print int(sum/NR)}' latency-log.txt)
    
    if [ "$AVG_LATENCY" -lt 200 ]; then
        MAX_JOBS=20
    elif [ "$AVG_LATENCY" -lt 500 ]; then
        MAX_JOBS=10
    else
        MAX_JOBS=5
    fi
fi

echo -e "${GREEN}🔎 Found $TOTAL_LINODES Linode IDs. Adjusting parallel jobs to $MAX_JOBS (Avg Latency: $AVG_LATENCY ms)${NC}"

# --- Step 3: Function to fetch VLAN IPs for a single Linode ---
fetch_vlan_ips() {
    local LID=$1
    local TEMP_FILE=$(mktemp)
    local TEMP_RESPONSE=$(mktemp)
    echo -e "${GREEN}🔎 Checking Linode ID: $LID${NC}"

    # Fetch configurations for the Linode with retry logic and X-Filter for interfaces
    URL="https://api.linode.com/v4/linode/instances/$LID/configs"
    retry_curl "$URL" "$TEMP_RESPONSE"

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ [ERROR] Failed to fetch configs for Linode ID $LID${NC}" | tee -a error-log.txt
        return 1
    fi

    # Extract VLAN IPs directly (No additional curl calls)
    VLAN_IPS=$(cat "$TEMP_RESPONSE" | jq -r ".data[].interfaces[] | select(.purpose == \"vlan\") | .ipam_address")

    # Write to the temp file and success log
    if [ -n "$VLAN_IPS" ]; then
        echo "$VLAN_IPS" >> "$TEMP_FILE"
        echo -e "${GREEN}✅ [SUCCESS] VLAN IPs found for Linode ID $LID - $VLAN_IPS${NC}" | tee -a success-log.txt
    else
        echo -e "${YELLOW}⚠️ [INFO] No VLAN IPs found for Linode ID $LID${NC}" | tee -a success-log.txt
    fi

    # Append temp file to final output (atomic operation)
    if [ -s "$TEMP_FILE" ]; then
        cat "$TEMP_FILE" >> "$OUTPUT_FILE"
    fi

    rm -f "$TEMP_FILE" "$TEMP_RESPONSE"
}

# === Calculate IP addresses without ipcalc ===
NETWORK_PREFIX=$(echo $SUBNET | cut -d'/' -f2)
IFS=. read -r i1 i2 i3 i4 <<< "$(echo $SUBNET | cut -d'/' -f1)"

# Extract the IP segments correctly
IFS=. read -r i1 i2 i3 i4 <<< "$(echo "$SUBNET" | cut -d'/' -f1)"

# Sanity check
if [ -z "$i1" ] || [ -z "$i2" ] || [ -z "$i3" ]; then
    echo -e "${RED}[ERROR] Subnet parsing failed. Please check the subnet format.${NC}"
    exit 1
fi

# Network IP (x.x.x.0)
NETWORK_IP="${i1}.${i2}.${i3}.0/$NETWORK_PREFIX"

# First usable IP (x.x.x.1)
FIRST_IP="${i1}.${i2}.${i3}.1/$NETWORK_PREFIX"

# Broadcast IP (x.x.x.255)
BROADCAST_IP="${i1}.${i2}.${i3}.255/$NETWORK_PREFIX"

# Reserved IPs Array
RESERVED_IPS=("$NETWORK_IP" "$FIRST_IP" "$BROADCAST_IP")

log "Reserved IPs for subnet $SUBNET: ${RESERVED_IPS[*]}"

# Adding reserved IPs to $IP_FILE_PATH files
log "Adding reserved IPs to the allocation list for reserving it..."
for ip in "${RESERVED_IPS[@]}"; do
    if ! grep -q "^$ip$" "$IP_FILE_PATH"; then
        echo "$ip" >> "$IP_FILE_PATH"
        log "Reserved IP added to list: $ip"
    fi
done

# --- Export function and variables for parallel ---
export -f fetch_vlan_ips retry_curl
export LINODE_TOKEN OUTPUT_FILE MAX_RETRIES

# --- Step 4: Parallel Processing of Linode IDs ---
echo -e "${BLUE}🌐 Fetching VLAN IPs from configurations in parallel...${NC}"
cat linodes.txt | parallel -j "$MAX_JOBS" fetch_vlan_ips {}

# --- Cleanup ---
rm -f linodes.txt

# === Remove duplicates ===
sort -u "$OUTPUT_FILE" -o "$OUTPUT_FILE"

log "✅ VLAN IP file created at $OUTPUT_FILE"

# === Write to etcd using etcdctl txn ===
log "💾 Syncing IPs to etcd..."
log "✅ ETCD_ENDPOINTS is $ETCD_ENDPOINTS"

if [ -z "$ETCD_ENDPOINTS" ]; then
    log "[ERROR] ETCD_ENDPOINTS not set."
    exit 1
fi

export ETCDCTL_API=3

while IFS= read -r ip; do
    key="/vlan/ip/$ip"
    output=$(etcdctl --endpoints="$ETCD_ENDPOINTS" put --prev-kv "$key" "true" 2>&1)
    if [[ "$output" == *"prev_kv"* ]]; then
        log "🔁 IP $ip already exists in etcd, skipping."
    else
        log "✅ IP $ip synced to etcd."
    fi
done < "$OUTPUT_FILE"

log "🎉 Initialization and etcd sync complete."

echo -e "${GREEN}✅ VLAN IP Initialization Complete. IPs saved to etcd database."

# --- Final Output ---
cat "$OUTPUT_FILE"

log "✅ IP List Initialization Complete. Saved to $IP_FILE_PATH"
