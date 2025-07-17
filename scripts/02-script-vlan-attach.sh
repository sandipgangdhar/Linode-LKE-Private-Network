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
SUBNET="${SUBNET}"
export ROUTE_LIST="${ROUTE_LIST:-}"
VLAN_LABEL="${VLAN_LABEL}"
DEST_SUBNET="${DEST_SUBNET}"
ENABLE_PUSH_ROUTE="$(echo "$ENABLE_PUSH_ROUTE" | tr '[:upper:]' '[:lower:]')"  # flag to control route pushing
ENABLE_FIREWALL="$(echo "$ENABLE_FIREWALL" | tr '[:upper:]' '[:lower:]')" # flag to control FIREWALL Creation and attachment
LKE_CLUSTER_ID="${LKE_CLUSTER_ID}"

# === Function to Log Events ===
# This function logs events with a timestamp
log() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log "🔄 Starting VLAN Attachment Script..."

# Wait for DNS to resolve
function wait_for_dns() {
    while ! nslookup api.linode.com >/dev/null 2>&1; do
        log "🌐 DNS resolution failed. Retrying in 10 seconds..."
        sleep 10
    done
    log "✅ DNS resolution successful."
}

# 🧼 Cleanup old CoreDNS reboot lock if held by this node
REBOOT_LOCK_KEY="/coredns-reboot-lock"
CURRENT_NODE=$(hostname)
if [ -n "$ETCD_ENDPOINTS" ]; then
    # Wait for etcd DNS to resolve
    until nslookup etcd-0.etcd.kube-system.svc.cluster.local >/dev/null 2>&1; do
        log "🌐 Waiting for DNS to resolve etcd-0 during lock cleanup..."
        sleep 5
    done

    # Check and delete the lock if this node owns it
    LOCK_OWNER=$(etcdctl --endpoints "$ETCD_ENDPOINTS" get "$REBOOT_LOCK_KEY" --print-value-only 2>/dev/null)
    if [[ "$LOCK_OWNER" == "$CURRENT_NODE" ]]; then
        etcdctl --endpoints "$ETCD_ENDPOINTS" del "$REBOOT_LOCK_KEY"
        log "🧹 Removed stale CoreDNS reboot lock held by $CURRENT_NODE"
    fi
fi

# === Function to check if VLAN is already attached ===
is_vlan_attached() {
    wait_for_dns ⏳ Ensure DNS is up before calling Linode API
    VLAN_STATUS=$(linode-cli linodes config-view "$LINODE_ID" "$CONFIG_ID" --json | jq -r '.[0].interfaces[1].purpose // empty')
    if [ "$VLAN_STATUS" == "vlan" ]; then
        return 0
    else
        return 1
    fi
}

# Function: Detect Configured-But-Missing VLAN Interface and Trigger Reboot
function handle_vlan_configured_but_missing_interface() {
    set +e
    wait_for_dns
    VLAN_ATTACHED=$(linode-cli linodes config-view "$LINODE_ID" "$CONFIG_ID" --json | jq -r '.[0].interfaces[1].purpose // empty')
    set -e

    if [[ "$VLAN_ATTACHED" == "vlan" ]]; then
        set +e
        wait_for_dns
        VLAN_IP=$(linode-cli linodes config-view "$LINODE_ID" "$CONFIG_ID" --json | jq -r '.[0].interfaces[1].ipam_address // empty')
        set -e
        wait_for_dns
        VLAN_INTERFACE=$(ip -o addr show | grep "$VLAN_IP" | awk '{print $2}' | head -n1)

        if [[ -z "$VLAN_INTERFACE" ]]; then
            log "⚠️ VLAN is attached in config but the interface is missing. Reboot is likely pending from previous run."

            CURRENT_NODE=$(hostname)
            REBOOT_LOCK_KEY="/coredns-reboot-lock"
            ETCD_URL="http://etcd-0.etcd.kube-system.svc.cluster.local:2379"

            log "🔍 Checking if this node is hosting a CoreDNS pod..."
            set +e
            COREDNS_HOST=$(kubectl get pods -n kube-system -o json | jq -r \
                '.items[] | select(.metadata.labels["k8s-app"] == "kube-dns") | .spec.nodeName' \
                | grep -w "$CURRENT_NODE")
            KUBE_EXIT=$?
            set -e

            if [[ "$KUBE_EXIT" -ne 0 || -z "$COREDNS_HOST" ]]; then
                log "🚀 This node is NOT hosting a CoreDNS pod. Rebooting immediately..."
            else
                log "🧠 $CURRENT_NODE is hosting a CoreDNS pod. Serialized reboot enabled."

                ACQUIRED=false
                while [[ "$ACQUIRED" != true ]]; do
                    until nslookup etcd-0.etcd.kube-system.svc.cluster.local >/dev/null 2>&1; do
                        log "🌐 Waiting for DNS to resolve etcd-0..."
                        sleep 5
                    done

                    log "🔒 Attempting atomic lock via etcd transaction..."

                    TXN_PAYLOAD=$(cat <<EOF
{
  "compare": [
    {
      "key": "$(echo -n "$REBOOT_LOCK_KEY" | base64)",
      "target": "VERSION",
      "result": "EQUAL",
      "version": "0"
    }
  ],
  "success": [
    {
      "requestPut": {
        "key": "$(echo -n "$REBOOT_LOCK_KEY" | base64)",
        "value": "$(echo -n "$CURRENT_NODE" | base64)"
      }
    }
  ],
  "failure": [
    {
      "requestRange": {
        "key": "$(echo -n "$REBOOT_LOCK_KEY" | base64)"
      }
    }
  ]
}
EOF
)

                    RESPONSE=$(curl -s -X POST "$ETCD_URL/v3/kv/txn" \
                        -H "Content-Type: application/json" \
                        -d "$TXN_PAYLOAD")

                    if echo "$RESPONSE" | grep -q '"succeeded":true'; then
                        log "✅ Lock acquired by $CURRENT_NODE for CoreDNS reboot."
                        ACQUIRED=true
                    else
                        HOLDER=$(echo "$RESPONSE" | jq -r '.responses[0].response_range.kvs[0].value' | base64 -d)
                        log "⛔ Lock held by $HOLDER. Waiting 10s before retry..."
                        sleep 10
                    fi
                done
            fi

            # === Reboot logic ===
            log "🔁 Initiating reboot via Linode CLI to apply VLAN changes..."
            RETRY=0
            MAX_RETRIES=10

            while true; do
                set +e
                wait_for_dns
                linode-cli linodes reboot "$LINODE_ID"
                EXIT_CODE=$?
                set -e

                if [[ "$EXIT_CODE" -eq 0 ]]; then
                    log "✅ Reboot command succeeded."
                    break
                else
                    log "⚠️ Reboot failed (possibly Linode busy). Retrying in 5s... ($((RETRY+1))/$MAX_RETRIES)"
                    RETRY=$((RETRY + 1))
                    if [[ $RETRY -ge $MAX_RETRIES ]]; then
                        log "❌ Reboot failed after $MAX_RETRIES attempts. Sleeping indefinitely."
                        sleep infinity
                    fi
                    sleep 5
                fi
            done

            sleep 300
            log "⚠️ Node did not reboot as expected. Sleeping to avoid loop."
            sleep infinity
        fi
    fi
}

# === Function to push the route ===
push_route() {
    if [[ "$ENABLE_PUSH_ROUTE" == "true" ]]; then
        echo "📦 Parsing ROUTE_LIST from ConfigMap..."
        # 🌐 Check if any DEST_SUBNET is 172.17.0.0/16 and delete default Docker route if needed
        log "🔍 Scanning ROUTE_LIST to see if 172.17.0.0/16 is present..."

        if echo "$ROUTE_LIST" | grep -q 'dest_subnet: "172.17.0.0/16"'; then
            log "⚠️ Found route for 172.17.0.0/16 in ROUTE_LIST. Checking and deleting LKE Docker route if exists..."

            set +e
            ip route show | grep -q "^172.17.0.0/16.*docker0"
            DEFAULT_LKE_ROUTE_STATUS=$?
            set -e

            if [ $DEFAULT_LKE_ROUTE_STATUS -eq 0 ]; then
                set +e
                ip route delete 172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1
                DELETE_STATUS=$?
                set -e

                if [ $DELETE_STATUS -eq 0 ]; then
                    log "✅ Default LKE Docker Route for 172.17.0.0/16 successfully deleted"
                else
                    log "⚠️ Failed to delete LKE Docker route for 172.17.0.0/16. Please verify manually."
                fi
            else
                log "✅ No LKE Docker route for 172.17.0.0/16 found. Nothing to delete."
            fi
        else
            log "✅ ROUTE_LIST does not contain 172.17.0.0/16. Skipping Docker route check."
        fi

        echo "$ROUTE_LIST" | while read -r line; do
            if [[ "$line" =~ route_ip ]]; then
                ROUTE_IP=$(echo "$line" | awk -F': ' '{print $2}' | tr -d '"')
            elif [[ "$line" =~ dest_subnet ]]; then
                DEST_SUBNET=$(echo "$line" | awk -F': ' '{print $2}' | tr -d '"')

                if [[ -z "$ROUTE_IP" || "$ROUTE_IP" == "0.0.0.0" || -z "$DEST_SUBNET" || "$DEST_SUBNET" == "0.0.0.0/0" ]]; then
                    log "❌ ENABLE_PUSH_ROUTE is true, but ROUTE_IP or DEST_SUBNET is unset or invalid."
                    log "🛑 Skipping route push and sleeping indefinitely to avoid container crash loop."
                    sleep infinity
                fi
                log "🔁 Processing Route: $DEST_SUBNET via $ROUTE_IP"
                log "📦 ENABLE_PUSH_ROUTE: $ENABLE_PUSH_ROUTE"
                log "📦 ROUTE_IP: $ROUTE_IP"
                log "📦 DEST_SUBNET: $DEST_SUBNET"

                log "Checking the VLAN_INTERFACE..."
                # Extract the VLAN IP
                wait_for_dns ⏳ Ensure DNS is up before calling Linode API
                VLAN_IP=$(linode-cli linodes config-view "$LINODE_ID" "$CONFIG_ID" --json | jq -r '.[0].interfaces[1].ipam_address // empty')

                # Extract the IP portion (strip subnet)
                VLAN_IP_ADDR=$(echo "$VLAN_IP" | cut -d'/' -f1)
                log "VLAN IP is $VLAN_IP_ADDR..."
                VLAN_INTERFACE=$(ip -o addr | awk -v ip="$VLAN_IP_ADDR" '$0 ~ ip {print $2; exit}')
                log "📦 VLAN interface value is: $VLAN_INTERFACE"

                if [[ -z "$VLAN_INTERFACE" ]]; then
                    log "❌ Could not resolve VLAN interface for IP $VLAN_IP. Sleeping indefinitely..."
                    sleep infinity
                fi

                log "📦 ENABLE_PUSH_ROUTE value is: $ENABLE_PUSH_ROUTE"
                log "📦 ROUTE_IP value is: $ROUTE_IP"
                log "📦 DEST_SUBNET value is: $DEST_SUBNET"

                log "Checking if route already exists for $DEST_SUBNET..."
                set +e
                ip route show | grep -q "$DEST_SUBNET"
                STATUS=$?
                set -e

                if [ $STATUS -eq 0 ]; then
                    log "✅ Route $DEST_SUBNET already exists. Skipping addition."
                else
                    log "⚙️  Adding route $DEST_SUBNET via $ROUTE_IP on $VLAN_INTERFACE..."
                    set +e
                    ip route add "$DEST_SUBNET" via "$ROUTE_IP" dev $VLAN_INTERFACE
                    ADD_STATUS=$?
                    set -e

                    if [ $ADD_STATUS -eq 0 ]; then
                        log "✅ Route $DEST_SUBNET via $ROUTE_IP successfully added to eth1."
                    else
                        log "⚠️  Failed to add route $DEST_SUBNET via $ROUTE_IP. It may already exist."
                    fi
                fi
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
    wait_for_dns # ⏳ Ensure DNS is up before calling Linode API
    FIREWALL_ID=$(linode-cli firewalls list --json 2>/dev/null | jq -r ".[] | select(.label==\"$FIREWALL_LABEL\") | .id")
    set -e

    if [[ -z "$FIREWALL_ID" ]]; then
        log "🚀 Creating new firewall with label $FIREWALL_LABEL..."
        set +e
        wait_for_dns # ⏳ Ensure DNS is up before calling Linode API
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
            wait_for_dns # ⏳ Ensure DNS is up before calling Linode AP
            FIREWALL_ID=$(linode-cli firewalls list --json | jq -r ".[] | select(.label==\"$FIREWALL_LABEL\") | .id")
            set -e
            if [[ -z "$FIREWALL_ID" ]]; then
                log "❌ Firewall creation failed and it does not exist. Sleeping indefinitely."
                sleep infinity
            else
                log "✅ Firewall was created by another process. Continuing with ID $FIREWALL_ID"
            fi
        else
            wait_for_dns # ⏳ Ensure DNS is up before calling Linode API
            FIREWALL_ID=$(linode-cli firewalls list --json | jq -r ".[] | select(.label==\"$FIREWALL_LABEL\") | .id")
            log "✅ Firewall created with ID $FIREWALL_ID"
        fi
        wait_for_dns # ⏳ Ensure DNS is up before calling Linode API
        FIREWALL_ID=$(linode-cli firewalls list --json | jq -r ".[] | select(.label==\"$FIREWALL_LABEL\") | .id")
        log "✅ Firewall created with ID $FIREWALL_ID"
    else
        log "✅ Firewall $FIREWALL_LABEL already exists with ID $FIREWALL_ID"
    fi

    # Check if any firewall is already attached to this Linode
    log "🔍 Verifying if Linode ID $LINODE_ID already has any firewall attached..."
    wait_for_dns ⏳ Ensure DNS is up before calling Linode API
    FIREWALLS_WITH_ENTITIES=$(linode-cli firewalls list --json | jq -r '.[] | select(.entities != null) | @base64')
    for fw in $FIREWALLS_WITH_ENTITIES; do
        _jq() { echo "$fw" | base64 --decode | jq -r "$1"; }
        FW_ID=$(_jq '.id')
        wait_for_dns # ⏳ Ensure DNS is up before calling Linode API
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
    wait_for_dns ⏳ Ensure DNS is up before calling Linode API
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
            wait_for_dns # ⏳ Ensure DNS is up before calling Linode API
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
LINODE_ID=""
TARGET_IP="$PUBLIC_IP"

# Step 1: Fetch page 1 and extract total pages from CLI output
log "📄 Fetching page 1 to detect total number of pages..."
PAGE_OUTPUT=$(linode-cli linodes list --page 1 --page-size 100)
HEADER_LINE=$(echo "$PAGE_OUTPUT" | tail -n 1)
TOTAL_PAGES=$(echo "$HEADER_LINE" | grep -oP 'Page 1 of \K[0-9]+')

# Fallback in case parsing fails
if [[ -z "$TOTAL_PAGES" ]]; then
    TOTAL_PAGES=1
    log "⚠️ Could not determine total pages. Defaulting to 1."
fi

log "📄 Total Pages Detected: $TOTAL_PAGES"

# Step 2: Loop over the actual number of pages
for page in $(seq 1 $TOTAL_PAGES); do
    log "🔍 Searching Linode list: Page $page"
    wait_for_dns

    result=$(linode-cli linodes list --page $page --page-size 100 --json)
    LINODE_ID=$(echo "$result" | jq -r --arg ip "$TARGET_IP" '.[] | select(.ipv4[]? == $ip) | .id')

    if [[ -n "$LINODE_ID" ]]; then
        log "✅ Found Linode with IP $TARGET_IP. LINODE_ID: $LINODE_ID"
        break
    fi
done

# Final check
if [[ -z "$LINODE_ID" ]]; then
    log "❌ Failed to find Linode with public IP $TARGET_IP in $TOTAL_PAGES pages."
    exit 1
fi

wait_for_dns # ⏳ Ensure DNS is up before calling Linode API
CONFIG_ID=$(linode-cli linodes configs-list $LINODE_ID --json | jq -r '.[0].id')

# Checking If the Linode ID or Config ID is found Correctly, retry after 60 seconds
MATCH_COUNT=$(echo "$LINODE_ID" | wc -w)
if [[ "$MATCH_COUNT" -ne 1 ]]; then
    log "❌ Ambiguous or no Linode match found for IP $PUBLIC_IP (Count: $MATCH_COUNT). Aborting."
    sleep 60
    /tmp/02-script-vlan-attach.sh
    exit 1
fi

# If either the Linode ID or Config ID is not found, retry after 60 seconds
if [ -z "$LINODE_ID" ] || [ -z "$CONFIG_ID" ]; then
    log "❌ Failed to retrieve Linode ID or Config ID. Sleeping for 60 seconds and retrying..."
    sleep 60
    /tmp/02-script-vlan-attach.sh
    exit 0
fi

log "✅ Linode ID: $LINODE_ID, Config ID: $CONFIG_ID"

# === Main Logic ===
handle_vlan_configured_but_missing_interface
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
wait_for_dns # ⏳ Ensure DNS is up before calling Linode API
linode-cli linodes config-update "$LINODE_ID" "$CONFIG_ID" --interfaces "$INTERFACES_JSON" --label "Boot Config"

# === Check VLAN is attached after attachment and firewall ===
if is_vlan_attached; then
    log "✅ VLAN is successfully attached now. Proceeding to reboot for changes to take effect..."

    touch /tmp/rebooting

    REBOOT_LOCK_KEY="/coredns-reboot-lock"
    CURRENT_NODE=$(hostname)
    export ETCDCTL_API=3

    if [ -z "$ETCD_ENDPOINTS" ]; then
        log "❌ ETCD_ENDPOINTS not set. Aborting reboot!"
        sleep infinity
    fi

    log "🔍 Checking if this node is hosting a CoreDNS pod..."
    set +e
    COREDNS_HOST=$(kubectl get pods -n kube-system -o json | jq -r \
        '.items[] | select(.metadata.labels["k8s-app"] == "kube-dns") | .spec.nodeName' \
        | grep -w "$CURRENT_NODE")
    KUBE_EXIT=$?
    set -e

    if [[ "$KUBE_EXIT" -ne 0 ]]; then
        log "⚠️ Failed to fetch CoreDNS pod status. Assuming no CoreDNS on this node. Proceeding with immediate reboot."
    fi

    if [[ -n "$COREDNS_HOST" ]]; then
        log "🧠 $CURRENT_NODE is hosting a CoreDNS pod. Serialized reboot enabled."

        ACQUIRED=false
        while [[ "$ACQUIRED" != true ]]; do
            until nslookup etcd-0.etcd.kube-system.svc.cluster.local >/dev/null 2>&1; do
                log "🌐 Waiting for DNS to resolve etcd-0..."
                sleep 5
            done

            log "🔒 Attempting atomic lock via etcd transaction..."

            BASE64_KEY=$(echo -n "$REBOOT_LOCK_KEY" | base64)
            BASE64_NODE=$(echo -n "$CURRENT_NODE" | base64)

            TXN_PAYLOAD=$(cat <<EOF
{
  "compare": [
    {
      "key": "$BASE64_KEY",
      "target": "VERSION",
      "result": "EQUAL",
      "version": "0"
    }
  ],
  "success": [
    {
      "requestPut": {
        "key": "$BASE64_KEY",
        "value": "$BASE64_NODE"
      }
    }
  ],
  "failure": [
    {
      "requestRange": {
        "key": "$BASE64_KEY"
      }
    }
  ]
}
EOF
)

            RESPONSE=$(curl -s -X POST "http://etcd-0.etcd.kube-system.svc.cluster.local:2379/v3/kv/txn" \
              -H "Content-Type: application/json" \
              -d "$TXN_PAYLOAD")

            if echo "$RESPONSE" | grep -q '"succeeded":true'; then
                log "✅ Lock acquired by $CURRENT_NODE for CoreDNS reboot."
                ACQUIRED=true
            else
                HOLDER=$(echo "$RESPONSE" | jq -r '.responses[0].response_range.kvs[0].value' | base64 -d)
                log "⛔ Lock held by $HOLDER. Waiting 10s before retry..."
                sleep 10
            fi
        done
    else
        log "🚀 This node is NOT hosting a CoreDNS pod. Rebooting immediately..."
    fi

    # === Reboot logic ===
    log "🔁 Initiating reboot via Linode CLI..."
    RETRY=0
    MAX_RETRIES=10

    while true; do
        set +e
        wait_for_dns # ⏳ Ensure DNS is up before calling Linode API
        linode-cli linodes reboot "$LINODE_ID"
        EXIT_CODE=$?
        set -e

        if [[ "$EXIT_CODE" -eq 0 ]]; then
            log "✅ Reboot command succeeded."
            break
        else
            log "⚠️ Reboot failed (possibly Linode busy). Retrying in 5s... ($((RETRY+1))/$MAX_RETRIES)"
            RETRY=$((RETRY + 1))
            if [[ $RETRY -ge $MAX_RETRIES ]]; then
                log "❌ Reboot failed after $MAX_RETRIES attempts. Sleeping indefinitely."
                sleep infinity
            fi
            sleep 5
        fi
    done

    sleep 300
    log "⚠️ Node did not reboot as expected. Sleeping to avoid loop."
    sleep infinity
else
    log "❌ VLAN check failed after config. Retrying in 60s..."
    sleep 60
    /tmp/02-script-vlan-attach.sh
    exit 1
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
