#!/bin/bash

# === Exit on error ===
set -e

# === Environment Variables ===
SUBNET="${SUBNET}"
ROUTE_IP="${ROUTE_IP}"
VLAN_LABEL="${VLAN_LABEL}"
DEST_SUBNET="${DEST_SUBNET}"

# === Logging function ===
log() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# === Function to check if VLAN is already attached ===
is_vlan_attached() {
    VLAN_STATUS=$(linode-cli linodes config-view "$LINODE_ID" "$CONFIG_ID" --json | jq -r '.[0].interfaces[1].purpose // empty')
    if [ "$VLAN_STATUS" == "vlan" ]; then
        return 0
    else
        return 1
    fi
}

# === Function to push the route ===
push_route() {
    log "Checking if route already exists for $DEST_SUBNET..."
    
    # Temporarily disable exit-on-error
    set +e
    ip route show | grep -q "$DEST_SUBNET"
    STATUS=$?
    set -e
    
    if [ $STATUS -eq 0 ]; then
        log "✅ Route $DEST_SUBNET already exists. Skipping addition."
    else
        log "⚙️  Adding route $DEST_SUBNET via $ROUTE_IP on eth1..."
        
        # Attempt to add the route
        set +e
        ip route add "$DEST_SUBNET" via "$ROUTE_IP" dev eth1
        ADD_STATUS=$?
        set -e

        if [ $ADD_STATUS -eq 0 ]; then
            log "✅ Route $DEST_SUBNET via $ROUTE_IP successfully added to eth1."
        else
            log "⚠️  Failed to add route $DEST_SUBNET via $ROUTE_IP. It may already exist."
        fi
    fi
}

# === Discover Linode Information ===
NODE_IP=$(ip addr show eth0 | grep 'inet ' | awk '{print $2}' | grep '^192\.' | cut -d/ -f1)
NODE_NAME=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.addresses[]?.address == "'"$NODE_IP"'") | .metadata.name')

log "🌐 Fetching Public IP of the instance..."
PUBLIC_IP=$(kubectl get node $NODE_NAME -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}' | awk {'print $1'})

export LINODE_CLI_CONFIG="/root/.linode-cli/linode-cli"

log "🔍 Discovering Linode ID for IP $PUBLIC_IP..."
LINODE_ID=$(linode-cli linodes list --json | jq -r ".[] | select(.ipv4[] | contains(\"$PUBLIC_IP\")) | .id")
CONFIG_ID=$(linode-cli linodes configs-list $LINODE_ID --json | jq -r '.[0].id')

if [ -z "$LINODE_ID" ] || [ -z "$CONFIG_ID" ]; then
    log "❌ Failed to retrieve Linode ID or Config ID. Sleeping for 60 seconds and retrying..."
    sleep 60
    /tmp/02-script-vlan-attach.sh
    exit 0
fi

log "✅ Linode ID: $LINODE_ID, Config ID: $CONFIG_ID"

# === Main Logic ===
log "🔎 Checking if VLAN is already attached to Linode instance $LINODE_ID..."
if is_vlan_attached; then
    log "✅ VLAN is already attached. Skipping VLAN configuration and directly pushing the route."
    push_route
    log "🛌 VLAN configuration complete. Sleeping indefinitely..."
    sleep infinity
fi

# === VLAN Configuration Logic with Retry ===
log "❌ VLAN is not attached. Proceeding with VLAN configuration..."
MAX_RETRIES=5
RETRY_COUNT=0
SUCCESS=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    log "🔄 Attempting to allocate IP address... (Attempt $((RETRY_COUNT+1))/$MAX_RETRIES)"
    
    set +e
    IP_ADDRESS1=$(/tmp/03-script-ip-allocate.sh $SUBNET)
    STATUS=$?
    set -e

    if [ $STATUS -eq 0 ]; then
        IP_ADDRESS=$(echo $IP_ADDRESS1 | awk {'print $NF'})
        if [ -n "$IP_ADDRESS" ]; then
            log "✅ Allocated IP address: $IP_ADDRESS"
            SUCCESS=true
            break
        else
            log "⚠️  No IP address found in response. Retrying..."
        fi
    else
        log "❌ IP allocation script failed. Retrying..."
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    sleep 5
done

if [ "$SUCCESS" = false ]; then
    log "❌ IP allocation failed after $MAX_RETRIES attempts. Retrying in 60 seconds..."
    sleep 60
    /tmp/02-script-vlan-attach.sh
    exit 0
fi

# === Build VLAN JSON ===
log "⚙️  Building VLAN attachment JSON..."
INTERFACES_JSON=$(jq -n --arg ip "$IP_ADDRESS" --arg vlan "$VLAN_LABEL" '
    [
      { "type": "public", "purpose": "public" },
      { "type": "vlan", "label": $vlan, "purpose": "vlan", "ipam_address": $ip }
    ]
')
echo $INTERFACES_JSON | jq .

# === Attach the VLAN interface ===
log "⚙️  Attaching VLAN interface to Linode instance..."
linode-cli linodes config-update "$LINODE_ID" "$CONFIG_ID" --interfaces "$INTERFACES_JSON" --label "Boot Config"

# === Check Success ===
if is_vlan_attached; then
    log "✅ VLAN successfully attached. Rebooting Linode..."
    touch /tmp/rebooting 
    linode-cli linodes reboot "$LINODE_ID"
    sleep infinity
else
    log "❌ VLAN configuration failed. Retrying in 60 seconds..."
    sleep 60
    /tmp/02-script-vlan-attach.sh
    exit 0
fi

# === Cleanup Logic ===
cleanup() {
    if [ -f "/tmp/rebooting" ]; then
        log "Skipping IP release due to planned reboot."
        rm -rfv /tmp/rebooting
    else
        log "Releasing IP address $IP_ADDRESS..."
        /tmp/04-script-ip-release.sh "$IP_ADDRESS"
        log "IP address $IP_ADDRESS released."
    fi
}
trap cleanup EXIT

log "✅ VLAN Attachment completed successfully."
log "🌐 Instance $LINODE_ID is now connected to VLAN $VLAN_LABEL with IP $IP_ADDRESS."
log "🛌 Script execution complete. Sleeping indefinitely..."
sleep infinity
