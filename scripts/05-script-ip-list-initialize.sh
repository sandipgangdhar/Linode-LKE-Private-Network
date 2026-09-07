#!/bin/bash
# 05-script-ip-list-initialize.sh
#
# This shell script initializes the IP list for the VLAN Manager in Linode LKE.
# It scans the provided subnet range, generates all usable IP addresses, and
# stores them in a list that can be used for VLAN IP allocation.
#
# -----------------------------------------------------
# Parameters:
#
# 1. SUBNET               - The subnet from which IPs are initialized.
# 2. IP_FILE_PATH         - The file where the initialized IP list is stored.
#
# -----------------------------------------------------
# Usage:
#
# - This script is executed during the initialization of VLAN Manager.
# - It parses the subnet and generates all usable IP addresses.
# - Reserved IPs (first, second, and last) are skipped.
#
# -----------------------------------------------------
# Best Practices:
#
# - Ensure the IP file path is writable before execution.
# - Monitor logs for any subnet parsing or IP conflicts.
# - Handle edge cases where the IP file already has data.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# © Linode-LKE-Private-Network | Developed by Sandip Gangdhar | 2025
#
# Exit on error / unset variable / failed pipeline stage.
# (Previously `set -euxo` - missing the "pipefail" argument to `-o` meant
# pipefail was never actually enabled, and `-o` with no argument instead
# just dumped the full `set -o` option-status listing on every run - that's
# the "allexport off / braceexpand on / ..." block you'd see at the top of
# every job log. Also dropped `-x` (xtrace) since it makes every run log
# the full command trace; add `bash -x` manually if you need that for
# debugging a specific run.)
set -euo pipefail

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
# LOG_LEVEL (env, default INFO) gates verbosity: DEBUG < INFO < WARN < ERROR.
#
# Deliberately a `case` (not an associative array keyed by level) to compute
# the rank: fetch_vlan_ips/retry_curl below are `export -f`'d and invoked by
# GNU parallel, which runs each one in a genuinely separate bash process, not
# a forked subshell of this one. `export -f` carries a function's own body
# across that boundary, but bash cannot export array variables at all (only
# plain scalars and function bodies) - an associative array referenced here
# would simply be unset/empty in those child processes, and this script's
# `set -u` would abort on the first log call any of them made.
log() {
    local level="$1"; shift
    local configured="${LOG_LEVEL:-INFO}"
    local rank threshold
    case "$level" in
        DEBUG) rank=0 ;;
        WARN)  rank=2 ;;
        ERROR) rank=3 ;;
        *)     rank=1 ;;  # INFO and any unrecognized level
    esac
    case "$configured" in
        DEBUG) threshold=0 ;;
        WARN)  threshold=2 ;;
        ERROR) threshold=3 ;;
        *)     threshold=1 ;;
    esac
    (( rank < threshold )) && return 0
    echo "[INITIALIZER] [$level] $(date '+%Y-%m-%d %H:%M:%S') $*"
}
export -f log

# === Validate Subnet is Provided ===
# If the subnet is not passed as an argument, exit with an error
log DEBUG "Script received SUBNET=$SUBNET REGION=$REGION"

if [ -z "$SUBNET" ]; then
    log ERROR "No subnet provided for initialization."
    exit 1
fi

# === Validate if Region is Provided ===
# If the region is not passed as an argument, exit with an error
if [ -z "$REGION" ]; then
    log ERROR "No REGION provided for initialization."
    exit 1
fi

log INFO "Starting IP List Initialization..."

log INFO "Subnet provided for initialization: $SUBNET"

# --- Retry Logic Wrapper with Intelligent Backoff and 404 Handling ---
#
# NOTE on two real bugs fixed here:
# 1) The final "did we ever succeed" check used to have no `return 1` on the
#    exhausted-retries path - a bash `if` with a false condition and no
#    `else` returns exit status 0 regardless of what the condition tested,
#    so every caller's `if [ $? -ne 0 ]` silently saw "success" even when
#    every retry failed, and proceeded to parse an empty/error response as
#    if it were real data.
# 2) `((RETRY_COUNT++))` is a classic bash gotcha: `(( expr ))` returns exit
#    status 1 ("false") when the value of expr is 0 - and a post-increment's
#    value is the value *before* incrementing. So on the very first retry
#    (RETRY_COUNT going from 0 to 1), this returned exit status 1, which -
#    under this script's `set -e` - killed the entire initializer outright
#    instead of just retrying. Using `RETRY_COUNT=$((RETRY_COUNT + 1))`
#    (a plain assignment, not the `(( ))` compound command) avoids this.
retry_curl() {
    local URL=$1
    local OUTPUT=$2
    local RETRY_COUNT=0
    local BACKOFF=1
    local SUCCESS=false

    while [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; do
        log DEBUG "Attempting API call: $URL (attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)"

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
                    log DEBUG "API call successful (${DURATION}ms): $URL"
                    break
                fi
                ;;
            404)
                log WARN "[404] Resource not found: $URL - skipping further retries for this resource."
                return 1
                ;;
            429)
                log WARN "Rate limit hit on $URL. Backing off for ${BACKOFF}s..."
                sleep "$BACKOFF"
                BACKOFF=$((BACKOFF * BACKOFF_BASE))
                ;;
            *)
                log WARN "API call to $URL failed with HTTP code $HTTP_CODE, retrying in ${BACKOFF}s..."
                sleep "$BACKOFF"
                BACKOFF=$((BACKOFF * BACKOFF_BASE))
                ;;
        esac

        RETRY_COUNT=$((RETRY_COUNT + 1))
    done

    if [ "$SUCCESS" = false ]; then
        log ERROR "API call failed after $MAX_RETRIES attempts: $URL"
        return 1
    fi
    return 0
}

# --- Step 1: Paginated Fetch for All Linode IDs in the region with X-Filter ---
log INFO "Fetching Linode IDs in region $REGION with pagination..."
while [ "$CURRENT_PAGE" -le "$TOTAL_PAGES" ]; do
    log DEBUG "Fetching page $CURRENT_PAGE of $TOTAL_PAGES"

    URL="https://api.linode.com/v4/linode/instances?page=$CURRENT_PAGE&page_size=$PAGE_SIZE"
    TEMP_RESPONSE=$(mktemp)

    # Fetch paginated data with retry logic. Guarded with `if !` rather than a
    # bare call + later `$?` check: under `set -e`, a failing bare command is
    # fatal at the point it runs, before a later `$?` check is ever reached -
    # only a command directly inside an `if`/`while` condition is exempt.
    if ! retry_curl "$URL" "$TEMP_RESPONSE"; then
        log ERROR "Failed to fetch page $CURRENT_PAGE of Linode instances in region $REGION after $MAX_RETRIES retries - aborting rather than proceeding with an incomplete IP inventory (see the retry warnings above for the underlying HTTP failures)."
        rm -f "$TEMP_RESPONSE"
        exit 1
    fi

    # Fetch Linode IDs and append to file
    cat "$TEMP_RESPONSE" | jq -r '.data[] | .id' >> linodes.txt
    
    # Get pagination info
    TOTAL_PAGES=$(cat "$TEMP_RESPONSE" | jq -r '.pages')
    CURRENT_PAGE=$((CURRENT_PAGE + 1))
    rm -f "$TEMP_RESPONSE"
done

# --- Step 2: Count the number of Linode IDs and adjust MAX_JOBS ---
TOTAL_LINODES=$(wc -l < linodes.txt)
# Always have a value for AVG_LATENCY - with `set -u`, referencing it later
# while unset (e.g. when TOTAL_LINODES is 0 or below INITIAL_JOBS, which
# skips the latency-based branch entirely) would kill the whole job.
AVG_LATENCY="N/A"

if [ "$TOTAL_LINODES" -eq 0 ]; then
    MAX_JOBS=0
    log WARN "No Linode instances found in region $REGION - nothing to scan for existing VLAN IPs. If you expected existing instances here, double-check REGION in the ConfigMap matches where they actually live."
elif [ "$TOTAL_LINODES" -lt "$INITIAL_JOBS" ]; then
    MAX_JOBS="$TOTAL_LINODES"
else
    # --- Adjust parallel jobs based on latency ---
    if [ -s latency-log.txt ]; then
        AVG_LATENCY=$(awk '{sum+=$3} END {print int(sum/NR)}' latency-log.txt)
    else
        AVG_LATENCY=0
    fi

    if [ "$AVG_LATENCY" -lt 200 ]; then
        MAX_JOBS=20
    elif [ "$AVG_LATENCY" -lt 500 ]; then
        MAX_JOBS=10
    else
        MAX_JOBS=5
    fi
fi

log INFO "Found $TOTAL_LINODES Linode IDs. Adjusting parallel jobs to $MAX_JOBS (avg latency: ${AVG_LATENCY}ms)"

# --- Step 3: Function to fetch VLAN IPs for a single Linode ---
fetch_vlan_ips() {
    local LID=$1
    local TEMP_FILE=$(mktemp)
    local TEMP_RESPONSE=$(mktemp)
    log DEBUG "Checking Linode ID: $LID"

    # Fetch configurations for the Linode with retry logic and X-Filter for interfaces.
    # Guarded with `if !` for the same set -e reason noted in Step 1 above -
    # this now actually matters, since fetch_vlan_ips runs as its own
    # subshell under GNU parallel and a bare-command failure here would kill
    # that one subshell before this function's own error handling ever ran.
    URL="https://api.linode.com/v4/linode/instances/$LID/configs"
    if ! retry_curl "$URL" "$TEMP_RESPONSE"; then
        log ERROR "Failed to fetch configs for Linode ID $LID after $MAX_RETRIES retries - skipping this instance (it will not contribute to the VLAN IP inventory this run)."
        rm -f "$TEMP_FILE" "$TEMP_RESPONSE"
        return 1
    fi

    # Extract VLAN IPs directly (No additional curl calls)
    VLAN_IPS=$(cat "$TEMP_RESPONSE" | jq -r ".data[].interfaces[] | select(.purpose == \"vlan\") | .ipam_address")

    # Write to the temp file
    if [ -n "$VLAN_IPS" ]; then
        echo "$VLAN_IPS" >> "$TEMP_FILE"
        log INFO "VLAN IP(s) found for Linode ID $LID: $VLAN_IPS"
    else
        log DEBUG "No VLAN IPs found for Linode ID $LID"
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

log INFO "Reserved IPs for subnet $SUBNET: ${RESERVED_IPS[*]}"

# Adding reserved IPs to $IP_FILE_PATH files
log INFO "Adding reserved IPs to the allocation list for reserving it..."
for ip in "${RESERVED_IPS[@]}"; do
    if ! grep -q "^$ip$" "$IP_FILE_PATH"; then
        echo "$ip" >> "$IP_FILE_PATH"
        log INFO "Reserved IP added to list: $ip"
    fi
done

# --- Export function and variables for parallel ---
export -f fetch_vlan_ips retry_curl
export LINODE_TOKEN OUTPUT_FILE MAX_RETRIES

# --- Step 4: Parallel Processing of Linode IDs ---
echo -e "${BLUE}Fetching VLAN IPs from configurations in parallel...${NC}"
cat linodes.txt | parallel -j "$MAX_JOBS" fetch_vlan_ips {}

# --- Cleanup ---
rm -f linodes.txt

# === Remove duplicates ===
sort -u "$OUTPUT_FILE" -o "$OUTPUT_FILE"

log INFO "VLAN IP file created at $OUTPUT_FILE"

# === Write to etcd using etcdctl txn ===
log INFO "Syncing IPs to etcd..."
log INFO "ETCD_ENDPOINTS is $ETCD_ENDPOINTS"

if [ -z "$ETCD_ENDPOINTS" ]; then
    log INFO "[ERROR] ETCD_ENDPOINTS not set."
    exit 1
fi

export ETCDCTL_API=3

while IFS= read -r ip; do
    key="/vlan/ip/$ip"
    output=$(etcdctl --endpoints="$ETCD_ENDPOINTS" put --prev-kv "$key" "true" 2>&1)
    if [[ "$output" == *"prev_kv"* ]]; then
        log INFO "IP $ip already exists in etcd, skipping."
    else
        log INFO "IP $ip synced to etcd."
    fi
done < "$OUTPUT_FILE"

log INFO "Initialization and etcd sync complete."

echo -e "${GREEN}VLAN IP Initialization Complete. IPs saved to etcd database."

# --- Final Output ---
cat "$OUTPUT_FILE"

log INFO "IP List Initialization Complete. Saved to $IP_FILE_PATH"
