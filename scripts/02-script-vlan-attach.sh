#!/bin/bash
set -e

# === Environment Variables ===
# These variables are populated from Kubernetes ConfigMap or environment
SUBNET="${SUBNET}"
export ROUTE_LIST="${ROUTE_LIST:-}"
VLAN_LABEL="${VLAN_LABEL}"
DEST_SUBNET="${DEST_SUBNET}"

ENABLE_PUSH_ROUTE="$(echo "$ENABLE_PUSH_ROUTE" | tr '[:upper:]' '[:lower:]')"   # control route pushing
ENABLE_FIREWALL="$(echo "$ENABLE_FIREWALL" | tr '[:upper:]' '[:lower:]')"       # control Linode Firewall
LKE_CLUSTER_ID="${LKE_CLUSTER_ID}"

# === New VPC + VLAN-EW firewall config ===
ENABLE_VPC_INTERFACE="$(echo "${ENABLE_VPC_INTERFACE:-false}" | tr '[:upper:]' '[:lower:]')"
VPC_SUBNET_ID="${VPC_SUBNET_ID:-}"                     # numeric Linode VPC subnet_id
VPC_INTERFACE_INDEX="${VPC_INTERFACE_INDEX:-2}"        # interface index for eth2

ENABLE_VLAN_EW_FIREWALL="$(echo "${ENABLE_VLAN_EW_FIREWALL:-false}" | tr '[:upper:]' '[:lower:]')"
VLAN_INTERFACE_NAME="${VLAN_INTERFACE_NAME:-eth1}"     # override if needed, default eth1

# === Function to Log Events ===
log() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log "🔄 Starting VLAN + VPC Attachment Script..."

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

# === Function to check if VLAN is already attached (interfaces[1]) ===
is_vlan_attached() {
    wait_for_dns ⏳ Ensure DNS is up before calling Linode API
    VLAN_STATUS=$(linode-cli linodes config-view "$LINODE_ID" "$CONFIG_ID" --json | jq -r '.[0].interfaces[1].purpose // empty')
    if [ "$VLAN_STATUS" == "vlan" ]; then
        return 0
    else
        return 1
    fi
}

# === Function to check if VPC is already attached (interfaces[VPC_INTERFACE_INDEX]) ===
is_vpc_attached() {
    # Do NOT depend on ENABLE_VPC_INTERFACE here; just read actual config
    wait_for_dns ⏳ Ensure DNS is up before calling Linode API

    local idx="${VPC_INTERFACE_INDEX:-2}"
    local PURPOSE

    PURPOSE=$(linode-cli linodes config-view "$LINODE_ID" "$CONFIG_ID" --json \
        | jq -r ".[0].interfaces[$idx].purpose // empty")

    if [[ "$PURPOSE" == "vpc" ]]; then
        return 0
    else
        return 1
    fi
}

# === Serialized reboot logic (CoreDNS-aware) ===
serialized_reboot() {
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
        wait_for_dns ⏳ Ensure DNS is up before calling Linode API
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
}

# === Function: Detect Configured-But-Missing VLAN Interface and Trigger Reboot ===
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

# === Helper: get VLAN interface name (eth1 or detected by IP) ===
get_vlan_interface_name() {
    if [[ -n "$VLAN_INTERFACE_NAME" ]]; then
        echo "$VLAN_INTERFACE_NAME"
        return 0
    fi

    wait_for_dns ⏳ Ensure DNS is up before calling Linode API
    local VLAN_IP
    VLAN_IP=$(linode-cli linodes config-view "$LINODE_ID" "$CONFIG_ID" --json \
        | jq -r '.[0].interfaces[1].ipam_address // empty')

    if [[ -z "$VLAN_IP" ]]; then
        log "❌ Could not read VLAN ipam_address from config. Falling back to eth1."
        echo "eth1"
        return 0
    fi

    local VLAN_IP_ADDR
    VLAN_IP_ADDR=$(echo "$VLAN_IP" | cut -d'/' -f1)

    local IFACE
    IFACE=$(ip -o addr | awk -v ip="$VLAN_IP_ADDR" '$0 ~ ip {print $2; exit}')

    if [[ -z "$IFACE" ]]; then
        log "⚠️ Could not detect interface for VLAN IP $VLAN_IP_ADDR. Falling back to eth1."
        echo "eth1"
    else
        echo "$IFACE"
    fi
}

# === VLAN east–west firewall rules (idempotent) ===
configure_vlan_ew_firewall() {
    if [[ "$ENABLE_VLAN_EW_FIREWALL" != "true" ]]; then
        log "ℹ️ Skipping VLAN east–west firewall; ENABLE_VLAN_EW_FIREWALL != true."
        return 0
    fi

    local VLAN_IF
    VLAN_IF=$(get_vlan_interface_name)

    log "🛡️ Enforcing VLAN east–west firewall on interface: $VLAN_IF"

    # 1. Allow responses to node-initiated connections on VLAN
    if iptables -C INPUT -i "$VLAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
        log "✅ Rule already present: ACCEPT ESTABLISHED,RELATED on $VLAN_IF"
    else
        iptables -A INPUT -i "$VLAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        log "➕ Added rule: ACCEPT ESTABLISHED,RELATED on $VLAN_IF"
    fi

    # 2. Drop all NEW inbound on VLAN (no one should initiate to workers on VLAN)
    if iptables -C INPUT -i "$VLAN_IF" -m conntrack --ctstate NEW -j DROP 2>/dev/null; then
        log "✅ Rule already present: DROP NEW on $VLAN_IF"
    else
        iptables -A INPUT -i "$VLAN_IF" -m conntrack --ctstate NEW -j DROP
        log "➕ Added rule: DROP NEW on $VLAN_IF"
    fi
}

# === Attach only VPC interface when VLAN is already present ===
attach_vpc_interface_only() {
    if [[ "$ENABLE_VPC_INTERFACE" != "true" ]]; then
        log "ℹ️ VPC interface management disabled. Skipping VPC attach."
        return 0
    fi

    if [[ -z "$VPC_SUBNET_ID" ]]; then
        log "❌ ENABLE_VPC_INTERFACE=true but VPC_SUBNET_ID is empty. Sleeping to avoid loops."
        sleep infinity
    fi

    if is_vpc_attached; then
        log "✅ VPC interface already attached. Skipping VPC config-update."
        return 0
    fi

    log "🚀 Attaching VPC interface (subnet_id=$VPC_SUBNET_ID) at interfaces[$VPC_INTERFACE_INDEX]..."
    wait_for_dns ⏳ Ensure DNS is up before calling Linode API

    local CONFIG_JSON
    CONFIG_JSON=$(linode-cli linodes config-view "$LINODE_ID" "$CONFIG_ID" --json | jq '.[0]')

    local UPDATED_INTERFACES
    UPDATED_INTERFACES=$(echo "$CONFIG_JSON" | jq --argjson subnet_id "$VPC_SUBNET_ID" '
        .interfaces | .['"$VPC_INTERFACE_INDEX"'] = { "purpose": "vpc", "subnet_id": $subnet_id }
    ')

    wait_for_dns ⏳ Ensure DNS is up before calling Linode API
    linode-cli linodes config-update "$LINODE_ID" "$CONFIG_ID" --interfaces "$UPDATED_INTERFACES"

    log "✅ VPC interface successfully attached as eth${VPC_INTERFACE_INDEX}."
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
                        log "✅ Route $DEST_SUBNET via $ROUTE_IP successfully added to $VLAN_INTERFACE."
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
log "🌐 Fetching NODE IP of the instance..."
NODE_IP=$(ip addr show eth0 | grep -v "eth0:[0-9]" | grep -w inet | awk {'print $2'}|awk -F'/' {'print $1'})
log "🌐 Node IP: $NODE_IP"

log "🌐 Fetching NODE NAME of the instance..."
NODE_NAME=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.addresses[]?.address == "'"$NODE_IP"'") | .metadata.name')
log "🌐 Node Name: $NODE_NAME"

# === VLAN Ready Label Helpers ===
mark_node_vlan_ready() {
    log "🏷️ Marking node '$NODE_NAME' as vlan-ready=true (unblocks app scheduling via Kyverno)..."
    kubectl label node "$NODE_NAME" vlan-ready=true --overwrite
    log "✅ Node label applied: vlan-ready=true"
}

clear_node_vlan_ready_label() {
    log "🏷️ Clearing node '$NODE_NAME' vlan-ready label (blocks app scheduling via Kyverno)..."
    kubectl label node "$NODE_NAME" vlan-ready- 2>/dev/null || true
}

# === Fetch Public IP of the Node ===
log "🌐 Fetching Public IP of the instance..."
PUBLIC_IP=$(kubectl get node $NODE_NAME -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}' | awk {'print $1'})
log "🌐 Public IP of the Node: $PUBLIC_IP"

export LINODE_CLI_CONFIG="/root/.linode-cli/linode-cli"

# === Discover Linode ID and Configuration ID ===
log "🌐 Finding Linode ID for Public IP: $PUBLIC_IP"
LINODE_ID=""
TARGET_IP="$PUBLIC_IP"

page=1
while true; do
    log "🔍 Searching Linode list: Page $page"
    wait_for_dns

    result=$(linode-cli linodes list --page $page --page-size 100 --json)

    if [[ $(echo "$result" | jq 'length') -eq 0 ]]; then
        break
    fi

    LINODE_ID=$(echo "$result" | jq -r --arg ip "$TARGET_IP" '.[] | select(.ipv4[]? == $ip) | .id')

    if [[ -n "$LINODE_ID" ]]; then
        log "✅ Found Linode with IP $TARGET_IP. LINODE_ID: $LINODE_ID"
        break
    fi

    page=$((page + 1))
done

if [[ -z "$LINODE_ID" ]]; then
    log "❌ Failed to find Linode with public IP $TARGET_IP."
    exit 1
fi

wait_for_dns
CONFIG_ID=$(linode-cli linodes configs-list "$LINODE_ID" --json | jq -r '.[0].id')

if [ -z "$CONFIG_ID" ]; then
    log "❌ Failed to retrieve configuration ID for Linode ID $LINODE_ID"
    exit 1
fi

log "✅ Linode ID: $LINODE_ID, Config ID: $CONFIG_ID"

# === Main Logic ===

# 1) Fix "configured but missing VLAN interface" first (ensures interface exists on OS)
handle_vlan_configured_but_missing_interface

# 2) Check current interface state
log "🔎 Checking existing VLAN/VPC attachment state for Linode instance $LINODE_ID..."
VLAN_PRESENT=false
VPC_PRESENT=false

if is_vlan_attached; then
    VLAN_PRESENT=true
fi
if is_vpc_attached; then
    VPC_PRESENT=true
fi

log "🔎 State summary: VLAN_PRESENT=${VLAN_PRESENT}, ENABLE_VPC_INTERFACE=${ENABLE_VPC_INTERFACE}, VPC_PRESENT=${VPC_PRESENT}"

# 2a) If VLAN is attached and VPC is either disabled or already attached => just do routes/firewall and iptables, no reboot
if [[ "$VLAN_PRESENT" == true && "$ENABLE_VPC_INTERFACE" == "true" && "$VPC_PRESENT" == false ]]; then
    log "ℹ️ VLAN is attached but VPC interface is missing. Attaching VPC and rebooting once..."
    attach_vpc_interface_only
    serialized_reboot
    sleep 300
    log "⚠️ Node did not reboot as expected after VPC attach. Sleeping to avoid loop."
    sleep infinity
fi

# 2b) VLAN attached and either:
#     - VPC is disabled (ENABLE_VPC_INTERFACE != true), OR
#     - VPC is already present
#     => No config-update, no reboot; just routes/firewall/iptables.
if [[ "$VLAN_PRESENT" == true ]]; then
    log "✅ VLAN is attached and VPC state is satisfied (either disabled or already present). Skipping config-update and reboot."
    push_route
    create_and_attach_firewall
    configure_vlan_ew_firewall
    # ✅ Unblock application scheduling only after success
    mark_node_vlan_ready
    log "🛌 VLAN/VPC configuration and firewall complete. Sleeping indefinitely..."
    sleep infinity
fi

# 3) VLAN is not attached => allocate VLAN IP and build interfaces list (VLAN + optional VPC), then reboot ONCE
log "❌ VLAN is not attached. Proceeding with VLAN (and optional VPC) configuration..."
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

# === Build VLAN (+optional VPC) JSON ===
log "⚙️  Building VLAN (and optionally VPC) attachment JSON..."

if [[ "$ENABLE_VPC_INTERFACE" == "true" && -n "$VPC_SUBNET_ID" ]]; then
    INTERFACES_JSON=$(jq -n --arg ip "$IP_ADDRESS" --arg vlan "$VLAN_LABEL" --argjson subnet_id "$VPC_SUBNET_ID" '
        [
          { "type": "public", "purpose": "public" },
          { "type": "vlan", "label": $vlan, "purpose": "vlan", "ipam_address": $ip },
          { "purpose": "vpc", "subnet_id": $subnet_id }
        ]
    ')
    log "📦 Configuring interfaces: public (eth0), VLAN (eth1), VPC (eth2)"
else
    INTERFACES_JSON=$(jq -n --arg ip "$IP_ADDRESS" --arg vlan "$VLAN_LABEL" '
        [
          { "type": "public", "purpose": "public" },
          { "type": "vlan", "label": $vlan, "purpose": "vlan", "ipam_address": $ip }
        ]
    ')
    log "📦 Configuring interfaces: public (eth0), VLAN (eth1)"
fi

echo "$INTERFACES_JSON" | jq .

# === Attach the VLAN (and optional VPC) interface(s) ===
log "⚙️  Attaching VLAN (and optional VPC) interface(s) to Linode instance..."
wait_for_dns # ⏳ Ensure DNS is up before calling Linode API
linode-cli linodes config-update "$LINODE_ID" "$CONFIG_ID" --interfaces "$INTERFACES_JSON" --label "Boot Config"

# === Check VLAN is attached after attachment and then reboot ONCE ===
if is_vlan_attached; then
    log "✅ VLAN is successfully attached now. Proceeding to reboot for changes to take effect..."

    # Mark that this run is performing a reboot so we don't release IP on EXIT
    touch /tmp/rebooting

    serialized_reboot

    sleep 300
    log "⚠️ Node did not reboot as expected. Sleeping to avoid loop."
    sleep infinity
else
    log "❌ VLAN check failed after config. Retrying in 60s..."
    sleep 60
    /tmp/02-script-vlan-attach.sh
    exit 1
fi

# === Cleanup Logic (currently not reached in normal flow, but kept for safety) ===
cleanup() {
    if [ -f "/tmp/rebooting" ]; then
        log "Skipping IP release due to planned reboot."
        rm -rfv /tmp/rebooting
    elif [ -n "$IP_ADDRESS" ]; then
        log "Releasing IP address $IP_ADDRESS..."
        /tmp/04-script-ip-release.sh "$IP_ADDRESS"
        log "IP address $IP_ADDRESS released."
    fi
}
trap cleanup EXIT

# ✅ Unblock application scheduling only after success
mark_node_vlan_ready

log "✅ VLAN Attachment completed successfully."
log "🌐 Instance $LINODE_ID is now connected to VLAN $VLAN_LABEL with IP $IP_ADDRESS."
log "🟢 VLAN, VPC (if enabled), Routes, Firewall, and VLAN-EW iptables configuration steps completed successfully."
log "🛌 Script execution complete. Sleeping indefinitely..."
sleep infinity
