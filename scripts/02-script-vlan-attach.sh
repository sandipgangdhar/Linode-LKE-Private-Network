#!/bin/bash
# 02-script-vlan-attach.sh
#
# This shell script handles the attachment of a VLAN interface to a Linode instance
# running in a Kubernetes environment. It configures IP addresses, VLAN labels,
# and routing information to enable communication across the VLAN.
#
# -----------------------------------------------------
# 📝 Parameters:
#
# 1️⃣ SUBNET              - The subnet for VLAN IP assignments.
# 2️⃣ ROUTE_IP            - Gateway IP for the primary subnet.
# 3️⃣ VLAN_LABEL          - VLAN identifier for Linode.
# 4️⃣ DEST_SUBNET         - Destination subnet for static routing.
#
# -----------------------------------------------------
# 🔄 Usage:
#
# - This script is executed as part of the DaemonSet startup.
# - It checks if the VLAN is attached to the instance and configures routing.
# - If the VLAN is not attached, it handles the attachment using Linode CLI.
#
# -----------------------------------------------------
# 📌 Best Practices:
#
# - Ensure proper RBAC permissions for `linode-cli` to execute API commands.
# - Monitor the logs for successful attachment and routing configuration.
# - Handle edge cases where VLAN or subnet configurations might fail.
#
# -----------------------------------------------------
# 🖋️ Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# © Linode-LKE-Private-Network | Developed by Sandip Gangdhar | 2025
# === Exit on error ===
set -e

# === Environment Variables ===
# These variables are populated from Kubernetes ConfigMap or environment
export SUBNET="${SUBNET}"
export ROUTE_LIST="${ROUTE_LIST:-}"
export VLAN_LABEL="${VLAN_LABEL}"
export ENABLE_PUSH_ROUTE="$(echo "$ENABLE_PUSH_ROUTE" | tr '[:upper:]' '[:lower:]')"  # flag to control route pushing
export ENABLE_FIREWALL="$(echo "$ENABLE_FIREWALL" | tr '[:upper:]' '[:lower:]')" # flag to control FIREWALL Creation and attachment
export LKE_CLUSTER_ID="${LKE_CLUSTER_ID}"

# === Function to Log Events ===
# This function logs events with a timestamp
log() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log "🔄 Starting VLAN Attachment Script..."

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
    if [[ "$ENABLE_PUSH_ROUTE" == "true" ]]; then
        echo "📦 Parsing ROUTE_LIST from ConfigMap..."

        echo "$ROUTE_LIST" | while read -r line; do
            if [[ "$line" =~ route_ip ]]; then
                ROUTE_IP=$(echo "$line" | awk -F': ' '{print $2}' | tr -d '"')
            elif [[ "$line" =~ dest_subnet ]]; then
                DEST_SUBNET=$(echo "$line" | awk -F': ' '{print $2}' | tr -d '"')
                
                # Ensure both values are present before continuing
                if [[ -z "$ROUTE_IP" || "$ROUTE_IP" == "0.0.0.0" || -z "$DEST_SUBNET" || "$DEST_SUBNET" == "0.0.0.0/0" ]]; then
                    log "❌ Skipping invalid route: ROUTE_IP=$ROUTE_IP DEST_SUBNET=$DEST_SUBNET"
                    unset ROUTE_IP DEST_SUBNET
                    continue
                fi

                log "🔁 Processing Route: $DEST_SUBNET via $ROUTE_IP"
                log "📦 ENABLE_PUSH_ROUTE: $ENABLE_PUSH_ROUTE"
                log "📦 ROUTE_IP: $ROUTE_IP"
                log "📦 DEST_SUBNET: $DEST_SUBNET"

                if [ "$DEST_SUBNET" == "172.17.0.0/16" ]; then
                    log "Checking if the default LKE route for $DEST_SUBNET exists"
                    set +e
                    ip route show | grep -q "$DEST_SUBNET"
                    DEFAULT_LKE_ROUTE_STATUS=$?
                    set -e

                    if [ $DEFAULT_LKE_ROUTE_STATUS -eq 0 ]; then
                        log "✅ Default LKE Route for $DEST_SUBNET already exists. Deleting it now."
                        set +e
                        ip route delete 172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1
                        DELETE_STATUS=$?
                        set -e

                        if [ $DELETE_STATUS -eq 0 ]; then
                            log "✅ Default LKE Route for $DEST_SUBNET successfully deleted..."
                        else
                            log "⚠️ Failed to delete default LKE route for $DEST_SUBNET. Please check it..."
                        fi
                    fi
                fi

                log "Checking if route already exists for $DEST_SUBNET..."
                set +e
                ip route show | grep -q "$DEST_SUBNET"
                STATUS=$?
                set -e

                if [ $STATUS -eq 0 ]; then
                    log "✅ Route $DEST_SUBNET already exists. Skipping addition."
                else
                    log "⚙️ Adding route $DEST_SUBNET via $ROUTE_IP on eth1..."
                    set +e
                    ip route add "$DEST_SUBNET" via "$ROUTE_IP" dev eth1
                    ADD_STATUS=$?
                    set -e

                    if [ $ADD_STATUS -eq 0 ]; then
                        log "✅ Route $DEST_SUBNET via $ROUTE_IP successfully added to eth1."
                    else
                        log "⚠️ Failed to add route $DEST_SUBNET via $ROUTE_IP. It may already exist or be invalid."
                    fi
                fi

                # Reset variables for next block
                unset ROUTE_IP DEST_SUBNET
            fi
        done
    else
        log "ℹ️ Skipping route push as ENABLE_PUSH_ROUTE is set to false."
    fi
}

# === Function to create and attach firewall ===
create_and_attach_firewall() {
    if [[ "$ENABLE_FIREWALL" != "true" ]]; then
        log "ℹ️ Skipping firewall creation as ENABLE_FIREWALL is set to false."
        return 0
    fi

    FIREWALL_LABEL="lke-cluster-firewall-${LKE_CLUSTER_ID}"
    log "🔍 Checking if firewall '$FIREWALL_LABEL' already exists..."

    set +e
    FIREWALL_ID=$(linode-cli firewalls list --json 2>/dev/null | jq -r ".[] | select(.label==\"$FIREWALL_LABEL\") | .id")
    set -e

    if [[ -z "$FIREWALL_ID" ]]; then
        log "🚀 Creating new firewall with label $FIREWALL_LABEL..."
        set +e
        CREATE_OUTPUT=$(linode-cli firewalls create \
          --label "$FIREWALL_LABEL" \
          --rules.inbound='[
            {"action": "ACCEPT", "protocol": "TCP", "ports": "10250,10256", "addresses": { "ipv4": ["192.168.128.0/17"] }, "label": "Kubelet_Health_Checks"},
            {"action": "ACCEPT", "protocol": "UDP", "ports": "51820", "addresses": { "ipv4": ["192.168.128.0/17"] }, "label": "kubectl_proxy_Wireguard_tunnel"},
            {"action": "ACCEPT", "protocol": "TCP", "ports": "53", "addresses": { "ipv4": ["192.168.128.0/17"] }, "label": "TCP_cluster_DNS_access"},
            {"action": "ACCEPT", "protocol": "UDP", "ports": "53", "addresses": { "ipv4": ["192.168.128.0/17"] }, "label": "UDP_cluster_DNS_access"},
            {"action": "ACCEPT", "protocol": "TCP", "ports": "179", "addresses": { "ipv4": ["192.168.128.0/17"] }, "label": "Calico_BGP_traffic"},
            {"action": "ACCEPT", "protocol": "TCP", "ports": "5473", "addresses": { "ipv4": ["192.168.128.0/17"] }, "label": "Calico_Typha_traffic"},
            {"action": "ACCEPT", "protocol": "TCP", "ports": "30000-32767", "addresses": { "ipv4": ["192.168.255.0/24"] }, "label": "NodeBalancer_TCP"},
            {"action": "ACCEPT", "protocol": "UDP", "ports": "30000-32767", "addresses": { "ipv4": ["192.168.255.0/24"] }, "label": "NodeBalancer_UDP"},
            {"action": "ACCEPT", "protocol": "IPENCAP", "addresses": { "ipv4": ["192.168.128.0/17"] }, "label": "NP_CP_communication"}
          ]' \
          --rules.outbound='[
            {"action": "ACCEPT", "protocol": "TCP", "ports": "1-65535", "addresses": { "ipv4": ["0.0.0.0/0"] }, "label": "Allow_All_TCP_Outbound"},
            {"action": "ACCEPT", "protocol": "UDP", "ports": "1-65535", "addresses": { "ipv4": ["0.0.0.0/0"] }, "label": "Allow_All_UDP_Outbound"}
          ]' \
          --rules.inbound_policy="DROP" \
          --rules.outbound_policy="ACCEPT" \
          --json)
        CREATE_STATUS=$?
        set -e

        if [[ $CREATE_STATUS -ne 0 || -z "$CREATE_OUTPUT" ]]; then
            log "⚠️ Firewall creation failed, checking if it was created by another node..."
            log "⚠️ First let's give 60 sec to Linode for creation...."
            sleep 60
            set +e
            FIREWALL_ID=$(linode-cli firewalls list --json | jq -r ".[] | select(.label==\"$FIREWALL_LABEL\") | .id")
            set -e
            if [[ -z "$FIREWALL_ID" ]]; then
                log "❌ Firewall creation failed and it does not exist. Sleeping indefinitely."
                sleep infinity
            else
                log "✅ Firewall was created by another process. Continuing with ID $FIREWALL_ID"
            fi
        else
            FIREWALL_ID=$(linode-cli firewalls list --json | jq -r ".[] | select(.label==\"$FIREWALL_LABEL\") | .id")
            log "✅ Firewall created with ID $FIREWALL_ID"
        fi
        FIREWALL_ID=$(linode-cli firewalls list --json | jq -r ".[] | select(.label==\"$FIREWALL_LABEL\") | .id")
        log "✅ Firewall created with ID $FIREWALL_ID"
    else
        log "✅ Firewall $FIREWALL_LABEL already exists with ID $FIREWALL_ID"
    fi

    # Check if any firewall is already attached to this Linode
    log "🔍 Verifying if Linode ID $LINODE_ID already has any firewall attached..."
    FIREWALLS_WITH_ENTITIES=$(linode-cli firewalls list --json | jq -r '.[] | select(.entities != null) | @base64')
    for fw in $FIREWALLS_WITH_ENTITIES; do
        _jq() { echo "$fw" | base64 --decode | jq -r "$1"; }
        FW_ID=$(_jq '.id')
        ENTITY_IDS=$(linode-cli firewalls view "$FW_ID" --json | jq -r '.[0].entities[]?.id')
        for id in $ENTITY_IDS; do
            if [[ "$id" == "$LINODE_ID" ]]; then
                log "⚠️ Linode ID $LINODE_ID already has a firewall attached (Firewall ID: $FW_ID). Skipping attachment."
                return 0
            fi
        done
    done

    log "🔗 Attaching firewall $FIREWALL_LABEL to Linode instance $LINODE_ID..."
    set +e
    linode-cli firewalls device-create "$FIREWALL_ID" --type linode --id "$LINODE_ID"
    ATTACH_STATUS=$?
    set -e

    if [[ $ATTACH_STATUS -eq 0 ]]; then
        # Wait for firewall to be fully attached before proceeding
        ATTACH_WAIT_RETRIES=10
        ATTACH_WAIT_DELAY=5
        ATTACH_CONFIRMED=false
        for i in $(seq 1 $ATTACH_WAIT_RETRIES); do
            set +e
            linode-cli firewalls devices-list "$FIREWALL_ID" --json | jq --argjson lid "$LINODE_ID" -e '.[] | select(.entity.id == $lid)' > /dev/null
            FIREWALL_DEVICE_STATUS=$?
            set -e
            if [[ "$FIREWALL_DEVICE_STATUS" -eq 0 ]]; then
                ATTACH_CONFIRMED=true
                log "✅ Firewall successfully attached to Linode ID $LINODE_ID"
                log "🛡️ Firewall ENABLED – Firewall '$FIREWALL_LABEL' (ID: $FIREWALL_ID) successfully created/attached to instance."
                log "✅ Firewall attachment complete. Continuing to finalize script execution..."
                break
            else
                log "⏳ Waiting for firewall to attach (attempt $i/$ATTACH_WAIT_RETRIES)..."
                sleep "$ATTACH_WAIT_DELAY"
            fi
        done
        if [[ "$ATTACH_CONFIRMED" != true ]]; then
            log "❌ Firewall did not attach within expected time for Linode ID $LINODE_ID"
            sleep infinity
        fi
    else
        log "❌ Failed to attach firewall to Linode ID $LINODE_ID. Sleeping indefinitely to avoid container restart loop."
        sleep infinity
    fi
}

# === Discover Node IP and Name ===
# Retrieve the IP address of eth0 (assumed to be the main interface)
log "🌐 Fetching NODE IP of the instance..."
NODE_IP=$(ip addr show eth0 | grep -v "eth0:[0-9]" | grep -w inet | awk {'print $2'}|awk -F'/' {'print $1'})

log "🌐 Node IP: $NODE_IP"

# Query Kubernetes to find the node name associated with this IP
log "🌐 Fetching NODE NAME of the instance..."
NODE_NAME=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.addresses[]?.address == "'"$NODE_IP"'") | .metadata.name')

log "🌐 Node Name: $NODE_NAME"

# === Fetch Public IP of the Node ===
# This fetches the public IP associated with the node from the Kubernetes API
log "🌐 Fetching Public IP of the instance..."
PUBLIC_IP=$(kubectl get node $NODE_NAME -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}' | awk {'print $1'})
log "🌐 Public IP of the Node: $PUBLIC_IP"

export LINODE_CLI_CONFIG="/root/.linode-cli/linode-cli"

# === Discover Linode ID and Configuration ID ===
# Linode API calls to find the instance ID and its configuration ID
LINODE_ID=$(kubectl get node "$(hostname)" -o json | jq -r '.spec.providerID' | cut -d '/' -f3)
CONFIG_ID=$(linode-cli linodes configs-list $LINODE_ID --json | jq -r '.[0].id')

# If either the Linode ID or Config ID is not found, retry after 60 seconds
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
    create_and_attach_firewall
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
    log "✅ VLAN successfully attached."
    create_and_attach_firewall
    touch /tmp/rebooting
    log "Rebooting Linode after firewall confirmed attached..."
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
log "🟢 VLAN and Firewall configuration steps completed successfully."
log "🛌 Script execution complete. Sleeping indefinitely..."
sleep infinity
