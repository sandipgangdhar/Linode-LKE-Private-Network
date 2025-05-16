#!/bin/bash
# Exit on error
set -e

# File paths for IP allocation
IP_FILE_PATH="/mnt/vlan-ip/vlan-ip-list.txt"
RESERVED_IP_FILE="/mnt/vlan-ip/reserved-ips.txt"
SUBNET=$1

# Logging function
log() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# === Check if the file already has data ===
if [ -f "$IP_FILE_PATH" ] && [ -s "$IP_FILE_PATH" ]; then
    log "IP List file already initialized. Skipping initialization."
    exit 0
fi

# Initialize the files if not present
if [ ! -f "$IP_FILE_PATH" ]; then
    log "Creating IP list file at $IP_FILE_PATH"
    touch $IP_FILE_PATH
fi

if [ ! -f "$RESERVED_IP_FILE" ]; then
    log "Creating Reserved IP list file at $RESERVED_IP_FILE"
    touch $RESERVED_IP_FILE
fi

if [ -z "$SUBNET" ]; then
    log "No subnet provided. Exiting..."
    exit 1
fi

# === Calculate IP addresses without ipcalc ===
NETWORK_PREFIX=$(echo $SUBNET | cut -d'/' -f2)
IFS=. read -r i1 i2 i3 i4 <<< "$(echo $SUBNET | cut -d'/' -f1)"

# Network IP (x.x.x.0)
NETWORK_IP="$i1.$i2.$i3.0/$NETWORK_PREFIX"

# First usable IP (x.x.x.1)
FIRST_IP="$i1.$i2.$i3.1/$NETWORK_PREFIX"

# Broadcast IP (x.x.x.255)
BROADCAST_IP="$i1.$i2.$i3.255/$NETWORK_PREFIX"

# Reserved IPs Array
RESERVED_IPS=("$NETWORK_IP" "$FIRST_IP" "$BROADCAST_IP")

log "Reserved IPs for subnet $SUBNET: ${RESERVED_IPS[*]}"

# Adding reserved IPs to both files
log "Adding reserved IPs to the allocation list and reserved list..."
for ip in "${RESERVED_IPS[@]}"; do
    if ! grep -q "^$ip$" "$IP_FILE_PATH"; then
        echo "$ip" >> "$IP_FILE_PATH"
        log "Reserved IP added to list: $ip"
    fi
    if ! grep -q "^$ip$" "$RESERVED_IP_FILE"; then
        echo "$ip" >> "$RESERVED_IP_FILE"
        log "Reserved IP added to reserved list: $ip"
    fi
done

log "Reserved IPs initialization completed."
