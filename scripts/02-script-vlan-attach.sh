#!/bin/bash

# Exit on error
set -e

# Environment Variables
SUBNET="${SUBNET:-192.168.0.0/16}"
ROUTE_IP="${ROUTE_IP:-192.168.0.1}"
VLAN_LABEL="${VLAN_LABEL:-vlan-1}"
DEST_SUBNET="${DEST_SUBNET:-10.0.0.0/16}"

# Logging function
log() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# Function to check if VLAN is already attached
is_vlan_attached() {
    VLAN_STATUS=$(linode-cli linodes config-view "$LINODE_ID" "$CONFIG_ID" --json | jq -r '.[0].interfaces[1].purpose // empty')
    if [ "$VLAN_STATUS" == "vlan" ]; then
        return 0
    else
        return 1
    fi
}

# Function to push the route
push_route() {
    ip route add "$DEST_SUBNET" via "$ROUTE_IP" dev eth1 2>/dev/null
    if [ $? -eq 0 ]; then
         log "Route $SUBNET via $ROUTE_IP successfully added to eth1."
    else
         log "Route $SUBNET via $ROUTE_IP already exists or failed to add."
    fi
}

# Get the External IP of the Node
NODE_IP=$(ip addr show eth0 | grep 'inet ' | awk '{print $2}' | grep '^192\.' | cut -d/ -f1)

# Get the Node Name
NODE_NAME=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.addresses[]?.address == "'"$NODE_IP"'") | .metadata.name')

# Discover Linode ID based on the instance's public IP
log "Fetching Public IP of the instance..."
PUBLIC_IP=$(kubectl get node $NODE_NAME -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}' | awk {'print $1'})

export LINODE_CLI_CONFIG="/root/.linode-cli/linode-cli"

log "Discovering Linode ID for IP $PUBLIC_IP..."
LINODE_ID=$(linode-cli linodes list --json | jq -r ".[] | select(.ipv4[] | contains(\"$PUBLIC_IP\")) | .id")
CONFIG_ID=$(linode-cli linodes configs-list $LINODE_ID --json | jq -r '.[0].id')

if [ -z "$LINODE_ID" ] || [ -z "$CONFIG_ID" ]; then
    log "Failed to retrieve Linode ID or Config ID. Exiting..."
    exit 1
fi

log "Linode ID: $LINODE_ID, Config ID: $CONFIG_ID"

# === Main Logic ===
log "Checking if VLAN is already attached to Linode instance $LINODE_ID..."
if is_vlan_attached; then
    log "VLAN is already attached. Skipping VLAN configuration and directly pushing the route."
    push_route
    exit 0
fi

# If VLAN is not attached, proceed with attachment
log "VLAN is not attached. Proceeding with VLAN configuration..."
# Allocate IP and release lock
IP_ADDRESS1=$(/tmp/03-script-ip-allocate.sh $SUBNET)
IP_ADDRESS=$(echo $IP_ADDRESS1 | awk {'print $NF'})

if [ -z "$IP_ADDRESS" ]; then
    log "No IP address available. Exiting..."
    exit 1
fi

log "Allocated IP address: $IP_ADDRESS"

# Build the JSON for VLAN attachment
log "Building VLAN attachment JSON..."
INTERFACES_JSON=$(jq -n --arg ip "$IP_ADDRESS" --arg vlan "$VLAN_LABEL" '
    [
      { "type": "public", "purpose": "public" },
      { "type": "vlan", "label": $vlan, "purpose": "vlan", "ipam_address": $ip }
    ]
')
echo $INTERFACES_JSON | jq .


# Attach the VLAN interface
log "Attaching VLAN interface to Linode instance..."
linode-cli linodes config-update "$LINODE_ID" "$CONFIG_ID" --interfaces "$INTERFACES_JSON" --label "Boot Config"

# Check if the update was successful
if [ $? -eq 0 ]; then
    echo "[INFO] Linode configuration update successful. Checking VLAN status on eth1..."
    if is_vlan_attached; then
       echo "[INFO] VLAN is successfully attached to eth1. Initiating reboot..."
       log "Rebooting Linode instance to apply VLAN configuration..."
       touch /tmp/rebooting
       linode-cli linodes reboot "$LINODE_ID"

       if [ $? -eq 0 ]; then
          echo "[INFO] Linode reboot successful."
       else
          echo "[ERROR] Linode reboot failed."
          exit 1
       fi
   else
      echo "[ERROR] Linode configuration update failed. Skipping reboot."
      exit 1
   fi
else
    echo "[ERROR] Linode configuration update failed. Skipping reboot."
    exit 1
fi


# Setup trap to release the IP if the node is deleted or the pod is terminated
cleanup() {
    if [ -f "/tmp/rebooting" ]; then
        echo "[INFO] Skipping IP release due to planned reboot."
        rm -rfv /tmp/rebooting
    else
        log "Releasing IP address $IP_ADDRESS..."
        /tmp/04-script-ip-release.sh "$IP_ADDRESS"
        log "IP address $IP_ADDRESS released."
    fi
}
trap cleanup EXIT

log "VLAN Attachment completed successfully."
log "Instance $LINODE_ID is now connected to VLAN $VLAN_LABEL with IP $IP_ADDRESS."
