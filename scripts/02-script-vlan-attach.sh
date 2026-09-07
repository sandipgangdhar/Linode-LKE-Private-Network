#!/bin/bash
set -euo pipefail

# === Function to Log Events ===
# LOG_LEVEL (env, default INFO) gates verbosity: DEBUG < INFO < WARN < ERROR.
# Defined first, before any other statement in this script, so every line
# below (including the earliest env-var setup) can use it consistently
# instead of falling back to a raw echo.
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
    echo "[$level] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

# === Environment Variables ===
# These variables are populated from Kubernetes ConfigMap or environment
ENABLE_VLAN="$(echo "${ENABLE_VLAN:-true}" | tr '[:upper:]' '[:lower:]')"
log INFO "ENABLE_VLAN is set to $ENABLE_VLAN"
SUBNET="${SUBNET}"
export ROUTE_LIST="${ROUTE_LIST:-}"
VLAN_LABEL="${VLAN_LABEL}"

ENABLE_PUSH_ROUTE="$(echo "$ENABLE_PUSH_ROUTE" | tr '[:upper:]' '[:lower:]')"   # control route pushing
ENABLE_FIREWALL="$(echo "$ENABLE_FIREWALL" | tr '[:upper:]' '[:lower:]')"       # control Linode Firewall
LKE_CLUSTER_ID="${LKE_CLUSTER_ID}"
LINODE_API_KEY="${LINODE_API_KEY}"
ETCD_ENDPOINTS="${ETCD_ENDPOINTS}"

# === New VPC + VLAN-EW firewall config ===
ENABLE_VPC_INTERFACE="$(echo "${ENABLE_VPC_INTERFACE:-false}" | tr '[:upper:]' '[:lower:]')"
VPC_SUBNET_ID="${VPC_SUBNET_ID:-}"                     # numeric Linode VPC subnet_id

ENABLE_VLAN_EW_FIREWALL="$(echo "${ENABLE_VLAN_EW_FIREWALL:-false}" | tr '[:upper:]' '[:lower:]')"

log INFO "Starting VLAN + VPC Attachment Script..."

# Wait for DNS to resolve
function wait_for_dns() {
    while ! nslookup api.linode.com >/dev/null 2>&1; do
        log INFO "DNS resolution failed. Retrying in 10 seconds..."
        sleep 10
    done
    log INFO "DNS resolution successful."
}

# Returns 0 if VLAN interface exists in Linode config, else 1
is_vlan_attached() {
  wait_for_dns

  local VLAN_COUNT
  VLAN_COUNT=$(linode-cli linodes config-view "$LINODE_ID" "$CONFIG_ID" --json 2>/dev/null \
    | jq -r '[.[0].interfaces[]? | select(.purpose=="vlan")] | length' 2>/dev/null)

  # Ensure numeric fallback
  VLAN_COUNT=${VLAN_COUNT:-0}

  if [[ "$VLAN_COUNT" =~ ^[0-9]+$ ]] && [[ "$VLAN_COUNT" -gt 0 ]]; then
      return 0
  else
      return 1
  fi
}

# Returns 0 if any VPC interface exists in Linode config, else 1
is_vpc_attached() {
  wait_for_dns

  local VPC_COUNT
  VPC_COUNT=$(linode-cli linodes config-view "$LINODE_ID" "$CONFIG_ID" --json \
    | jq '[.[0].interfaces[]? | select(.purpose=="vpc")] | length')

  # Ensure numeric fallback
  VPC_COUNT=${VPC_COUNT:-0}

  if [[ "$VPC_COUNT" =~ ^[0-9]+$ ]] && [[ "$VPC_COUNT" -gt 0 ]]; then
      return 0
  else
      return 1
  fi
}

is_coredns_on_node() {
  local node="$1"

  # Query only pods scheduled on THIS node (fast + accurate)
  kubectl get pods -n kube-system \
    --field-selector "spec.nodeName=${node}" \
    -o json | jq -e '
      .items[]? |
      (
        # Common labels in many clusters
        (.metadata.labels["k8s-app"] == "coredns") or
        (.metadata.labels["k8s-app"] == "kube-dns") or
        (.metadata.labels["app.kubernetes.io/name"] == "coredns") or

        # Some clusters use different app labels
        (.metadata.labels["app"] == "coredns") or
        (.metadata.labels["app"] == "workload-coredns") or

        # Fallback: name contains coredns (covers workload-coredns pods too)
        (.metadata.name | test("coredns"))
      )
    ' >/dev/null 2>&1
}

get_etcd_leader_endpoint() {
  export ETCDCTL_API=3

  if [[ -z "${ETCD_ENDPOINTS:-}" ]]; then
    log ERROR "ETCD_ENDPOINTS is not set"
    return 1
  fi

  # Optional: print status table for debugging (to STDERR only)
  etcdctl --endpoints="$ETCD_ENDPOINTS" endpoint status --cluster -w table >&2 || true

  # Extract leader endpoint using JSON (clean parse)
  local leader
  leader="$(
    etcdctl --endpoints="$ETCD_ENDPOINTS" endpoint status --cluster -w json 2>/dev/null \
    | jq -r '.[] | select(.Status.header.member_id == .Status.leader) | .Endpoint' \
    | head -n1
  )"

  # Validate result
  if [[ -z "$leader" || "$leader" == "null" ]]; then
    log ERROR "Could not detect etcd leader from endpoints: $ETCD_ENDPOINTS"
    return 1
  fi

  # Strip whitespace/newlines just in case
  leader="$(echo -n "$leader" | tr -d '\r\n' | xargs)"

  # Output ONLY the URL (this is critical)
  echo -n "$leader"
}

is_etcd_on_node() {
  local node="$1"
  kubectl get pods -n kube-system \
    --field-selector "spec.nodeName=${node}" \
    -l app=etcd \
    -o json | jq -e '.items | length > 0' >/dev/null 2>&1
}

is_controller_on_node() {
  local node="$1"

  kubectl get pods -n kube-system \
    --field-selector "spec.nodeName=${node}" \
    -o json | jq -e '
      .items[]? |
      (
        (.metadata.labels["app"] == "vlan-config-controller") or
        (.metadata.labels["app.kubernetes.io/name"] == "vlan-config-controller") or
        (.metadata.name | test("vlan-config-controller"))
      )
    ' >/dev/null 2>&1
}

get_vlan_ip_from_config() {
  wait_for_dns
  linode-cli linodes config-view "$LINODE_ID" "$CONFIG_ID" --json \
    | jq -r '.[0].interfaces[]? | select(.purpose=="vlan") | .ipam_address // empty' \
    | head -n1
}

etcd_healthy_count() {
  etcdctl --endpoints="$ETCD_ENDPOINTS" endpoint health 2>/dev/null \
  | grep -c "is healthy"
}

etcd_member_count() {
  etcdctl --endpoints="$ETCD_ENDPOINTS" member list 2>/dev/null \
  | wc -l
}

wait_for_etcd_quorum_after_this_node_goes_down() {
  local current_node="$1"
  export ETCDCTL_API=3

  while true; do

    # Get full cluster status as JSON
    local STATUS_JSON
    STATUS_JSON=$(etcdctl --endpoints="$ETCD_ENDPOINTS" endpoint status --cluster -w json 2>/dev/null)

    # If etcdctl failed
    if [[ -z "$STATUS_JSON" ]]; then
      log WARN "Unable to fetch etcd status. Retrying..."
      sleep 5
      continue
    fi

    # Total members in cluster
    local TOTAL
    TOTAL=$(echo "$STATUS_JSON" | jq 'length' 2>/dev/null)
    TOTAL="${TOTAL:-0}"

    # Count healthy endpoints (endpoint status succeeded)
    local HEALTHY
    HEALTHY=$(echo "$STATUS_JSON" | jq '[.[] | select(.Status != null)] | length' 2>/dev/null)
    HEALTHY="${HEALTHY:-0}"

    # Sanitize numeric values
    [[ "$TOTAL" =~ ^[0-9]+$ ]] || TOTAL=0
    [[ "$HEALTHY" =~ ^[0-9]+$ ]] || HEALTHY=0

    # Compute quorum
    local QUORUM
    QUORUM=$(( (TOTAL / 2) + 1 ))

    # Subtract 1 if this node hosts etcd
    local SAFE
    if is_etcd_on_node "$current_node"; then
      SAFE=$(( HEALTHY - 1 ))
    else
      SAFE=$HEALTHY
    fi

    log INFO "etcd cluster: Total=$TOTAL Healthy=$HEALTHY Quorum=$QUORUM SafeAfterShutdown=$SAFE"

    if (( SAFE >= QUORUM )); then
      return 0
    fi

    sleep 5
  done
}

# Reads lock owner from etcd (returns empty if missing)
get_lock_owner() {
  local etcd_primary="$1"
  local b64_key="$2"

  curl -s -X POST "${etcd_primary}/v3/kv/range" \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"${b64_key}\",\"serializable\":false}" \
  | jq -r '.kvs[0].value // empty' 2>/dev/null \
  | base64 -d 2>/dev/null || true
}

# === Helper: get VLAN interface name (eth1 or detected by IP) ===
get_vlan_interface_name() {

    wait_for_dns

    # -------------------------------------------------------
    # 1. Fetch VLAN ipam_address from Linode config
    # -------------------------------------------------------
    local VLAN_IP
    VLAN_IP=$(linode-cli linodes config-view "$LINODE_ID" "$CONFIG_ID" --json 2>/dev/null \
        | jq -r '.[0].interfaces[]? | select(.purpose=="vlan") | .ipam_address // empty' \
        | head -n1)

    if [[ -z "$VLAN_IP" ]]; then
        log ERROR "VLAN ipam_address not found in config."
        return 1
    fi

    local VLAN_IP_ADDR
    VLAN_IP_ADDR="${VLAN_IP%%/*}"

    log INFO "Looking for VLAN interface with IP $VLAN_IP_ADDR"

    # -------------------------------------------------------
    # 2. Retry detection (interface may take time to appear)
    # -------------------------------------------------------
    local RETRIES=15
    local IFACE=""

    while [[ $RETRIES -gt 0 ]]; do

        # Match exact IP in column 4 (safe match)
        IFACE=$(ip -o -4 addr show \
            | awk -v ip="$VLAN_IP_ADDR" '$4 ~ "^"ip"/" {print $2; exit}')

        if [[ -n "$IFACE" ]]; then
            # Ensure interface is UP
            if ip link show "$IFACE" | grep -q "state UP"; then
                log INFO "VLAN interface detected: $IFACE"
                printf "%s\n" "$IFACE"
                return 0
            else
                log INFO "Interface $IFACE found but not UP yet..."
            fi
        fi

        log INFO "Waiting for VLAN interface to appear..."
        sleep 2
        ((RETRIES--))
    done

    # -------------------------------------------------------
    # 3. Safe fallback logic
    # -------------------------------------------------------

    log WARN "Could not auto-detect VLAN interface by IP."

    # Enterprise cluster fallback → eth2
    if [[ "${LKE_CLUSTER_TYPE,,}" == "enterprise" ]]; then
        log WARN "Enterprise cluster fallback → returning eth2"
        printf "%s\n" "eth2"
        return 0
    fi

    # Standard LKE fallback → eth1
    log WARN "Standard cluster fallback → returning eth1"
    printf "%s\n" "eth1"
}

# === Serialized Shutdown logic ===
serialized_shutdown() {
  local REBOOT_LOCK_KEY="/coredns-reboot-lock"
  local CURRENT_NODE
  CURRENT_NODE="$(hostname)"
  export ETCDCTL_API=3

  if [[ -z "${ETCD_ENDPOINTS:-}" ]]; then
    log ERROR "ETCD_ENDPOINTS not set. Aborting shutdown!"
    sleep infinity
  fi

  # Pick first endpoint as primary (fine for reads/writes; etcd will redirect internally)
  local ETCD_PRIMARY
  ETCD_PRIMARY=$(get_etcd_leader_endpoint)

  # Base64 key/value for etcd v3 JSON API
  # NOTE: GNU base64 wraps output at 76 chars by default, inserting literal
  # newlines - which breaks a JSON string literal if embedded directly into
  # a curl -d payload. Always use -w 0 (no wrap) for anything going into
  # etcd's JSON API, even values that look "safe" today (short now doesn't
  # mean short forever - e.g. longer hostnames).
  local BASE64_KEY BASE64_NODE
  BASE64_KEY="$(echo -n "$REBOOT_LOCK_KEY" | base64 -w 0)"
  BASE64_NODE="$(echo -n "$CURRENT_NODE" | base64 -w 0)"

  # ------------------------------------------------------------
  # 1) Determine whether this node is "critical" for serialized shutdown
  #    Critical = hosts etcd OR CoreDNS OR controller
  # ------------------------------------------------------------
  log INFO "Checking if this node is hosting etcd..."
  local ETCD_CRIT=1
  if is_etcd_on_node "$CURRENT_NODE"; then
    ETCD_CRIT=0
    log INFO "ETCD detected on this node (${CURRENT_NODE})"
  else
    log INFO "ETCD not detected on this node (${CURRENT_NODE})"
  fi

  log INFO "Checking if this node is hosting CoreDNS..."
  local COREDNS_CRIT=1
  if is_coredns_on_node "$CURRENT_NODE"; then
    COREDNS_CRIT=0
    log INFO "CoreDNS detected on this node (${CURRENT_NODE})"
  else
    log INFO "CoreDNS not detected on this node (${CURRENT_NODE})"
  fi

  log INFO "Checking if this node is hosting CONTROLLER..."
  local CTRL_CRIT=1
  if is_controller_on_node "$CURRENT_NODE"; then
    CTRL_CRIT=0
    log INFO "Controller detected on this node (${CURRENT_NODE})"
  else
    log INFO "Controller not detected on this node (${CURRENT_NODE})"
  fi

  local IS_CRITICAL=1
  if (( ETCD_CRIT == 0 || COREDNS_CRIT == 0 || CTRL_CRIT == 0 )); then
    IS_CRITICAL=0
  fi

  # Non-critical nodes: no serialization required
  if (( IS_CRITICAL != 0 )); then
    log INFO "Non-critical node (no etcd/coredns/controller here). Proceeding with immediate shutdown."
    goto_shutdown=true
  else
    log INFO "Critical node detected (etcd/coredns/controller). Serialized shutdown enabled."
    goto_shutdown=false
  fi

  # ------------------------------------------------------------
  # 2) If critical: ensure etcd is reachable + quorum will survive *after* we go down
  #    This is the MOST important guard.
  # ------------------------------------------------------------
  if [[ "$goto_shutdown" == "false" ]]; then
    # Wait for DNS before etcd API calls
    ETCD_PRIMARY="$(get_etcd_leader_endpoint)"
    ETCD_PRIMARY_DNS=$(echo "$ETCD_PRIMARY" | sed -e 's|http://||g' -e 's|:2379||g')
    until nslookup $ETCD_PRIMARY_DNS >/dev/null 2>&1; do
      log INFO "Waiting for DNS to resolve $ETCD_PRIMARY_DNS..."
      sleep 5
    done

    log INFO "Ensuring etcd quorum before attempting lock..."
    wait_for_etcd_quorum_after_this_node_goes_down "$CURRENT_NODE"
  fi

  # ------------------------------------------------------------
  # 3) Acquire lock (critical nodes only)
  #    Lock semantics: create key only if it does NOT exist (VERSION == 0)
  # ------------------------------------------------------------
  if [[ "$goto_shutdown" == "false" ]]; then
    local ACQUIRED=false
    while [[ "$ACQUIRED" != "true" ]]; do
      log INFO "Attempting atomic lock via etcd transaction..."

      local TXN_PAYLOAD
      TXN_PAYLOAD=$(cat <<EOF
{
  "compare": [
    {
      "key": "${BASE64_KEY}",
      "target": "VERSION",
      "result": "EQUAL",
      "version": "0"
    }
  ],
  "success": [
    { "requestPut": { "key": "${BASE64_KEY}", "value": "${BASE64_NODE}" } }
  ],
  "failure": [
    { "requestRange": { "key": "${BASE64_KEY}" } }
  ]
}
EOF
)

      local RESPONSE
      RESPONSE="$(curl -s -X POST "${ETCD_PRIMARY}/v3/kv/txn" \
        -H "Content-Type: application/json" \
        -d "${TXN_PAYLOAD}")"

      if echo "$RESPONSE" | grep -q '"succeeded":true'; then
        # ------------------------------------------------------------
        # 3a) VERIFY: confirm we really own the lock via a range read
        #     This closes the race where leadership changes might make state ambiguous.
        # ------------------------------------------------------------
        local OWNER
        OWNER="$(get_lock_owner "$ETCD_PRIMARY" "$BASE64_KEY")"

        if [[ "$OWNER" == "$CURRENT_NODE" ]]; then
          log INFO "Lock acquired and verified as owned by ${CURRENT_NODE}"
          log INFO "Sleeping 30s to allow etcd leader to replicate the lock to Followers before shutdown..."
          sleep 30
          ACQUIRED=true
        else
          log WARN "Lock acquire returned success but owner verify mismatch (owner='${OWNER}'). Retrying..."
          sleep 5
          continue
        fi

        # ------------------------------------------------------------
        # 3b) CRITICAL FIX: Re-check quorum AFTER lock acquisition
        #     Prevents 2nd node shutting down immediately after 1st goes down.
        # ------------------------------------------------------------
        log INFO "Re-checking etcd quorum AFTER lock acquisition..."
        wait_for_etcd_quorum_after_this_node_goes_down "$CURRENT_NODE"

      else
        # Extract holder (best-effort)
        local HOLDER_B64 HOLDER
        HOLDER_B64="$(echo "$RESPONSE" | jq -r '.responses[0].response_range.kvs[0].value // empty' 2>/dev/null)"
        if [[ -n "$HOLDER_B64" ]]; then
          HOLDER="$(echo "$HOLDER_B64" | base64 -d 2>/dev/null || true)"
        else
          HOLDER="unknown"
        fi
        log WARN "Lock held by ${HOLDER}. Waiting 10s before retry..."
        sleep 10
      fi
    done

    # Optional stabilization (keeps your previous intent)
    log INFO "Sleeping 15s to allow etcd leader stabilization before shutdown..."
    sleep 15
  fi

  # ------------------------------------------------------------
  # 4) Shutdown logic (with retries)
  # ------------------------------------------------------------
  log INFO "Initiating Shutdown via Linode API..."

  local RETRY=0
  local MAX_RETRIES=10

  while true; do
    set +e
    wait_for_dns
    # This sleep exists for etcd leader stabilization - only meaningful for
    # a critical node (etcd/CoreDNS/controller). It used to run
    # unconditionally, adding 30s of pure dead time before every app-pool
    # node's shutdown too, for a concern that doesn't apply there at all.
    # Confirmed live (LKE Standard, cluster 648300) that this - stacked with
    # the offline-detection polling in vlan-config-controller's process_job()
    # afterward - pushed the total "node offline" window long enough that
    # LKE's own node-pool management repeatedly decided the node had failed
    # and rebuilt it from scratch (linode_delete + linode_create, not just a
    # reboot), wiping out the VLAN interface we'd just written and forcing
    # an infinite retry loop. A fast manual shutdown-reconfigure-reboot
    # cycle (well under a minute total) did not trigger this on the same
    # cluster - see docs/TROUBLESHOOTING.md entry 21.
    if (( IS_CRITICAL == 0 )); then
      log INFO "Sleeping 30s to allow etcd leader stabilization before shutdown..."
      sleep 30
    fi
    linode-cli linodes shutdown "$LINODE_ID"
    local EXIT_CODE=$?
    set -e

    if [[ "$EXIT_CODE" -eq 0 ]]; then
      log INFO "shutdown command succeeded."
      break
    fi

    RETRY=$((RETRY + 1))
    log WARN "shutdown failed. Retrying in 5s... (${RETRY}/${MAX_RETRIES})"
    if (( RETRY >= MAX_RETRIES )); then
      log ERROR "shutdown failed after ${MAX_RETRIES} attempts. Sleeping indefinitely."
      sleep infinity
    fi
    sleep 5
  done
}

# === Function: Detect Configured-But-Missing VLAN Interface and Trigger Reboot ===
handle_vlan_configured_but_missing_interface() {

    log INFO "Checking VLAN consistency..."

    wait_for_dns

    CONFIG_JSON=$(linode-cli linodes config-view "$LINODE_ID" "$CONFIG_ID" --json)
    VLAN_ATTACHED=$(echo "$CONFIG_JSON" | jq -r '.[0].interfaces[]? | select(.purpose=="vlan") | .purpose' | head -n1)

    if [[ "$VLAN_ATTACHED" != "vlan" ]]; then
        log INFO "No VLAN attached in config. Nothing to validate."
        return 0
    fi

    VLAN_INTERFACE=$(get_vlan_interface_name)

    if [[ -n "$VLAN_INTERFACE" ]]; then
        log INFO "VLAN interface present in OS ($VLAN_INTERFACE)."
        return 0
    fi

    log WARN "VLAN attached in config but OS interface missing."

    # -------------------------------------------------------
    # Check etcd desired state before acting
    # -------------------------------------------------------

    DESIRED_KEY="/vlan-config/${LINODE_ID}"
    ETCD_PRIMARY=$(get_etcd_leader_endpoint)

    RESPONSE=$(curl -s -X POST \
      "${ETCD_PRIMARY}/v3/kv/range" \
      -H "Content-Type: application/json" \
      -d "{
            \"key\": \"${BASE64_KEY}\",
            \"serializable\": false
          }")

    VALUE=$(echo "$RESPONSE" | jq -r '.kvs[0].value // empty')

    if [[ -z "$VALUE" ]]; then
        log WARN "No desired config found in etcd. Skipping auto-repair."
        return 0
    fi

    DESIRED_JSON=$(echo "$VALUE" | base64 -d)
    STATUS=$(echo "$DESIRED_JSON" | jq -r '.status')

    log INFO "etcd desired status = $STATUS"

    # -------------------------------------------------------
    # If controller still pending → do nothing
    # -------------------------------------------------------

    if [[ "$STATUS" == "pending" ]]; then
        log INFO "Controller has not completed config application yet. Waiting."
        return 0
    fi

    # -------------------------------------------------------
    # If controller marked applied but interface missing,
    # request a clean shutdown so controller can re-evaluate
    # -------------------------------------------------------

    log INFO "Interface missing but config applied. Initiating shutdown for reconciliation."

    serialized_shutdown
    exit 0
}


# === VLAN east–west firewall rules (idempotent) ===
configure_vlan_ew_firewall() {
    if [[ "$ENABLE_VLAN_EW_FIREWALL" != "true" ]]; then
        log INFO "Skipping VLAN east–west firewall; ENABLE_VLAN_EW_FIREWALL != true."
        return 0
    fi

    local VLAN_IF
    VLAN_IF=$(get_vlan_interface_name)

    log INFO "Enforcing VLAN east–west firewall on interface: $VLAN_IF"

    # 1. Allow responses to node-initiated connections on VLAN
    if iptables -C INPUT -i "$VLAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
        log INFO "Rule already present: ACCEPT ESTABLISHED,RELATED on $VLAN_IF"
    else
        iptables -A INPUT -i "$VLAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        log INFO "Added rule: ACCEPT ESTABLISHED,RELATED on $VLAN_IF"
    fi

    # 2. Drop all NEW inbound on VLAN (no one should initiate to workers on VLAN)
    if iptables -C INPUT -i "$VLAN_IF" -m conntrack --ctstate NEW -j DROP 2>/dev/null; then
        log INFO "Rule already present: DROP NEW on $VLAN_IF"
    else
        iptables -A INPUT -i "$VLAN_IF" -m conntrack --ctstate NEW -j DROP
        log INFO "Added rule: DROP NEW on $VLAN_IF"
    fi
}

# === Attach only VPC interface when VLAN is already present ===
attach_vpc_interface_only() {
  if [[ "${ENABLE_VPC_INTERFACE,,}" != "true" ]]; then
    log INFO "VPC interface management disabled."
    return 0
  fi

  if [[ -z "$VPC_SUBNET_ID" ]]; then
    log ERROR "ENABLE_VPC_INTERFACE=true but VPC_SUBNET_ID is empty."
    return 3
  fi

  if is_vpc_attached; then
    log INFO "VPC already attached."
    return 0
  fi

  log INFO "Attaching VPC interface (subnet_id=$VPC_SUBNET_ID)..."

  local current base updated
  current="$(get_current_interfaces)"

  # For Standard LKE, current may be [] (implicit public). That's OK.
  # For Enterprise, current must contain both vpc+public; build_base will enforce that.
  base="$(build_base_interfaces "$current")" || return $?

  # If standard base synthesized public, we can safely append VPC now.
  updated="$(echo "$base" | jq -c --argjson subnet_id "$VPC_SUBNET_ID" \
    '. + [{ "purpose":"vpc", "subnet_id":$subnet_id }]')"

  log INFO "==== CURRENT INTERFACES ===="
  echo "$current" | jq .
  log INFO "==== UPDATED INTERFACES ===="
  echo "$updated" | jq .

  wait_for_dns
  linode-cli linodes config-update "$LINODE_ID" "$CONFIG_ID" --interfaces "$updated"

  log INFO "VPC interface added."
  return 2
}

# === Function to push the route ===
push_route() {
    if [[ "$ENABLE_PUSH_ROUTE" == "true" ]]; then
        log INFO "Parsing ROUTE_LIST from ConfigMap..."
        # Check if any DEST_SUBNET is 172.17.0.0/16 and delete default Docker route if needed
        log INFO "Scanning ROUTE_LIST to see if 172.17.0.0/16 is present..."

        if echo "$ROUTE_LIST" | grep -q 'dest_subnet: "172.17.0.0/16"'; then
            log WARN "Found route for 172.17.0.0/16 in ROUTE_LIST. Checking and deleting LKE Docker route if exists..."

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
                    log INFO "Default LKE Docker Route for 172.17.0.0/16 successfully deleted"
                else
                    log WARN "Failed to delete LKE Docker route for 172.17.0.0/16. Please verify manually."
                fi
            else
                log INFO "No LKE Docker route for 172.17.0.0/16 found. Nothing to delete."
            fi
        else
            log INFO "ROUTE_LIST does not contain 172.17.0.0/16. Skipping Docker route check."
        fi

        echo "$ROUTE_LIST" | while read -r line; do
            if [[ "$line" =~ route_ip ]]; then
                ROUTE_IP=$(echo "$line" | awk -F': ' '{print $2}' | tr -d '"')
            elif [[ "$line" =~ dest_subnet ]]; then
                DEST_SUBNET=$(echo "$line" | awk -F': ' '{print $2}' | tr -d '"')

                if [[ -z "$ROUTE_IP" || "$ROUTE_IP" == "0.0.0.0" || -z "$DEST_SUBNET" ]]; then
                    log ERROR "ENABLE_PUSH_ROUTE is true, but ROUTE_IP or DEST_SUBNET is unset or invalid."
                    log WARN "Skipping route push and sleeping indefinitely to avoid container crash loop."
                    sleep infinity
                fi

                if [[ "$DEST_SUBNET" == "0.0.0.0/0" ]]; then
                    # ROUTE_LIST is for specific VPN/site-to-site subnets only.
                    # Routing ALL internet-bound traffic via a single NAT
                    # gateway is a different, dedicated feature - see the
                    # ENABLE_NAT_GATEWAY / NAT_GATEWAY_IP keys and
                    # push_nat_gateway_route() below. Keeping this rejected
                    # here (rather than silently accepting it) avoids a user
                    # hand-rolling a default-route override in this list
                    # without the metric-based demotion logic that a plain
                    # default route needs to actually coexist with - and win
                    # over - the node's own pre-existing default route.
                    log ERROR "ROUTE_LIST does not support dest_subnet: \"0.0.0.0/0\" - use ENABLE_NAT_GATEWAY/NAT_GATEWAY_IP instead for whole-of-internet routing via a NAT gateway. Sleeping indefinitely..."
                    sleep infinity
                fi

                log INFO "Processing Route: $DEST_SUBNET via $ROUTE_IP"
                log INFO "ENABLE_PUSH_ROUTE: $ENABLE_PUSH_ROUTE"
                log INFO "ROUTE_IP: $ROUTE_IP"
                log INFO "DEST_SUBNET: $DEST_SUBNET"

                log INFO "Checking the VLAN_INTERFACE..."
                VLAN_INTERFACE=$(get_vlan_interface_name)
                log INFO "VLAN interface value is: $VLAN_INTERFACE"

                if [[ -z "$VLAN_INTERFACE" ]]; then
                    log ERROR "Could not resolve VLAN interface. Sleeping indefinitely..."
                    sleep infinity
                fi

                log INFO "ENABLE_PUSH_ROUTE value is: $ENABLE_PUSH_ROUTE"
                log INFO "ROUTE_IP value is: $ROUTE_IP"
                log INFO "DEST_SUBNET value is: $DEST_SUBNET"

                log INFO "Checking if route already exists for $DEST_SUBNET..."
                set +e
                ip route show | grep -q "$DEST_SUBNET"
                STATUS=$?
                set -e

                if [ $STATUS -eq 0 ]; then
                    log INFO "Route $DEST_SUBNET already exists. Skipping addition."
                else
                    log INFO "Adding route $DEST_SUBNET via $ROUTE_IP on $VLAN_INTERFACE..."
                    # NOTE: the route gateway (ROUTE_IP) intentionally lives
                    # outside this node's own narrow VLAN allocation subnet
                    # (e.g. node is 10.95.255.x/24, gateway is 10.80.0.254) -
                    # they're both on the same large flat VLAN L2 segment,
                    # just different slices of it. Without `onlink`, the
                    # kernel refuses the route with "Nexthop has invalid
                    # gateway" because it only trusts the interface's own
                    # configured /24 as directly reachable. `onlink` tells
                    # the kernel to trust that this gateway is L2-adjacent
                    # via this device anyway, which is true for this network
                    # design (do not add this flag if the gateway is NOT
                    # actually on the same L2 segment as this interface).
                    set +e
                    ip route add "$DEST_SUBNET" via "$ROUTE_IP" dev $VLAN_INTERFACE onlink
                    ADD_STATUS=$?
                    set -e

                    if [ $ADD_STATUS -eq 0 ]; then
                        log INFO "Route $DEST_SUBNET via $ROUTE_IP successfully added to $VLAN_INTERFACE."
                    else
                        log WARN "Failed to add route $DEST_SUBNET via $ROUTE_IP. It may already exist."
                    fi
                fi
            fi
        done
    else
        log INFO "Skipping route push as ENABLE_PUSH_ROUTE is set to false."
    fi
}

# === Function to push a NAT gateway default route ===
#
# Dedicated, simplified feature for "route all of this node's internet-bound
# traffic via a single NAT gateway instance on the VLAN" - deliberately kept
# separate from push_route()/ROUTE_LIST above, which is for specific
# site-to-site VPN subnets. Only two end-user inputs: ENABLE_NAT_GATEWAY and
# NAT_GATEWAY_IP - the route metric and the demotion-offset for the node's
# own pre-existing default route are fixed internally (NAT_GATEWAY_METRIC /
# NAT_GATEWAY_OLD_DEFAULT_METRIC below), not exposed as ConfigMap keys. A
# user who needs "route all internet traffic via one box" does not also need
# to learn what a route metric is to get that - see the ConfigMap comment
# above ENABLE_NAT_GATEWAY for the full rationale.
#
# The demotion logic here is load-bearing, not cosmetic: `ip route replace
# default via X dev Y metric N` does NOT update an existing default route on
# the same dev/gateway that has no explicit metric - metric is part of the
# kernel's route key, so "unset" (effectively the highest-priority metric,
# 0) and "N" are two different routes, not the same route being updated.
# Skipping the explicit `ip route del` first would silently leave the node's
# original default route in place and still winning - confirmed live during
# this feature's initial testing (see docs/NAT-Test.md Tier 3): every log
# line looked correct and `ip route show` even displayed the right-looking
# result, but `ip route get <target>` (what actually matters) kept resolving
# via the node's untouched original default the entire time.
push_nat_gateway_route() {
    local ENABLE_NAT_GATEWAY_LC
    ENABLE_NAT_GATEWAY_LC="$(echo "${ENABLE_NAT_GATEWAY:-false}" | tr '[:upper:]' '[:lower:]')"

    if [[ "$ENABLE_NAT_GATEWAY_LC" != "true" ]]; then
        log INFO "Skipping NAT gateway route push; ENABLE_NAT_GATEWAY is not 'true'."
        return 0
    fi

    if [[ -z "${NAT_GATEWAY_IP:-}" ]]; then
        log ERROR "ENABLE_NAT_GATEWAY is true but NAT_GATEWAY_IP is unset. Sleeping indefinitely to avoid container crash loop..."
        sleep infinity
    fi

    # Fixed internally - not user-configurable, see function header above.
    local NAT_GATEWAY_METRIC=50
    local NAT_GATEWAY_OLD_DEFAULT_METRIC=150

    log INFO "Checking the VLAN_INTERFACE for NAT gateway route push..."
    VLAN_INTERFACE=$(get_vlan_interface_name)
    log INFO "VLAN interface value is: $VLAN_INTERFACE"

    if [[ -z "$VLAN_INTERFACE" ]]; then
        log ERROR "Could not resolve VLAN interface while pushing NAT gateway route. Sleeping indefinitely..."
        sleep infinity
    fi

    while read -r EXIST_DEV EXIST_GW; do
        [[ -z "$EXIST_DEV" || "$EXIST_DEV" == "$VLAN_INTERFACE" ]] && continue
        log INFO "Demoting existing default route via $EXIST_GW dev $EXIST_DEV to metric $NAT_GATEWAY_OLD_DEFAULT_METRIC so the NAT gateway default (metric $NAT_GATEWAY_METRIC) takes priority..."
        set +e
        ip route del default via "$EXIST_GW" dev "$EXIST_DEV"
        ip route replace default via "$EXIST_GW" dev "$EXIST_DEV" metric "$NAT_GATEWAY_OLD_DEFAULT_METRIC"
        set -e
    done < <(ip route show default | awk '{dev="";gw="";for(i=1;i<=NF;i++){if($i=="dev")dev=$(i+1);if($i=="via")gw=$(i+1)} if(dev!="") print dev, gw}')

    log INFO "Replacing default route via NAT gateway $NAT_GATEWAY_IP on $VLAN_INTERFACE (metric $NAT_GATEWAY_METRIC)..."
    set +e
    ip route replace default via "$NAT_GATEWAY_IP" dev $VLAN_INTERFACE onlink metric "$NAT_GATEWAY_METRIC"
    ADD_STATUS=$?
    set -e

    if [ $ADD_STATUS -eq 0 ]; then
        log INFO "Default route via NAT gateway $NAT_GATEWAY_IP (metric $NAT_GATEWAY_METRIC) successfully applied to $VLAN_INTERFACE."
    else
        log WARN "Failed to apply NAT gateway default route via $NAT_GATEWAY_IP on $VLAN_INTERFACE."
    fi
}

# === Function to create and attach firewall ===
create_and_attach_firewall() {
    # LKE Enterprise clusters ship with their own managed firewall by default -
    # this function's rules are hardcoded for Calico (BGP/Typha/IPIP), not
    # Cilium (what LKE-E actually runs), so creating/attaching a second,
    # custom firewall here would be redundant at best and could conflict with
    # or block traffic the managed firewall already accounts for at worst
    # (see docs/TROUBLESHOOTING.md #9). Deliberately ignore ENABLE_FIREWALL on
    # Enterprise - this is not a bug, it's an intentional override, not a
    # silent no-op, so it's logged clearly either way.
    if [[ "${LKE_CLUSTER_TYPE,,}" == "enterprise" ]]; then
        log INFO "LKE Enterprise detected - skipping custom firewall creation regardless of ENABLE_FIREWALL ('$ENABLE_FIREWALL'). LKE-E clusters come with their own managed firewall by default, and this function's rules are Calico-specific (LKE-E runs Cilium)."
        return 0
    fi

    if [[ "$ENABLE_FIREWALL" != "true" ]]; then
        log INFO "Skipping firewall creation as ENABLE_FIREWALL is set to false."
        return 0
    fi

    FIREWALL_LABEL="lke-cluster-firewall-${LKE_CLUSTER_ID}"
    log INFO "Checking if firewall '$FIREWALL_LABEL' already exists..."

    set +e
    wait_for_dns # Ensure DNS is up before calling Linode API
    FIREWALL_ID=$(linode-cli firewalls list --json 2>/dev/null | jq -r ".[] | select(.label==\"$FIREWALL_LABEL\") | .id")
    set -e

    if [[ -z "$FIREWALL_ID" ]]; then
        log INFO "Creating new firewall with label $FIREWALL_LABEL..."
        set +e
        wait_for_dns # Ensure DNS is up before calling Linode API
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
            log WARN "Firewall creation failed, checking if it was created by another node..."
            log WARN "First let's give 60 sec to Linode for creation...."
            sleep 60
            set +e
            wait_for_dns # Ensure DNS is up before calling Linode AP
            FIREWALL_ID=$(linode-cli firewalls list --json | jq -r ".[] | select(.label==\"$FIREWALL_LABEL\") | .id")
            set -e
            if [[ -z "$FIREWALL_ID" ]]; then
                log ERROR "Firewall creation failed and it does not exist. Sleeping indefinitely."
                sleep infinity
            else
                log INFO "Firewall was created by another process. Continuing with ID $FIREWALL_ID"
            fi
        else
            wait_for_dns # Ensure DNS is up before calling Linode API
            FIREWALL_ID=$(linode-cli firewalls list --json | jq -r ".[] | select(.label==\"$FIREWALL_LABEL\") | .id")
            log INFO "Firewall created with ID $FIREWALL_ID"
        fi
        wait_for_dns # Ensure DNS is up before calling Linode API
        FIREWALL_ID=$(linode-cli firewalls list --json | jq -r ".[] | select(.label==\"$FIREWALL_LABEL\") | .id")
        log INFO "Firewall created with ID $FIREWALL_ID"
    else
        log INFO "Firewall $FIREWALL_LABEL already exists with ID $FIREWALL_ID"
    fi

    # Check if any firewall is already attached to this Linode
    log INFO "Verifying if Linode ID $LINODE_ID already has any firewall attached..."
    wait_for_dns Ensure DNS is up before calling Linode API
    FIREWALLS_WITH_ENTITIES=$(linode-cli firewalls list --json | jq -r '.[] | select(.entities != null) | @base64')
    for fw in $FIREWALLS_WITH_ENTITIES; do
        _jq() { echo "$fw" | base64 --decode | jq -r "$1"; }
        FW_ID=$(_jq '.id')
        wait_for_dns # Ensure DNS is up before calling Linode API
        ENTITY_IDS=$(linode-cli firewalls view "$FW_ID" --json | jq -r '.[0].entities[]?.id')
        for id in $ENTITY_IDS; do
            if [[ "$id" == "$LINODE_ID" ]]; then
                log WARN "Linode ID $LINODE_ID already has a firewall attached (Firewall ID: $FW_ID). Skipping attachment."
                return 0
            fi
        done
    done

    log INFO "Attaching firewall $FIREWALL_LABEL to Linode instance $LINODE_ID..."
    set +e
    wait_for_dns Ensure DNS is up before calling Linode API
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
            wait_for_dns # Ensure DNS is up before calling Linode API
            linode-cli firewalls devices-list "$FIREWALL_ID" --json | jq --argjson lid "$LINODE_ID" -e '.[] | select(.entity.id == $lid)' > /dev/null
            FIREWALL_DEVICE_STATUS=$?
            set -e
            if [[ "$FIREWALL_DEVICE_STATUS" -eq 0 ]]; then
                ATTACH_CONFIRMED=true
                log INFO "Firewall successfully attached to Linode ID $LINODE_ID"
                log INFO "Firewall ENABLED – Firewall '$FIREWALL_LABEL' (ID: $FIREWALL_ID) successfully created/attached to instance."
                log INFO "Firewall attachment complete. Continuing to finalize script execution..."
                break
            else
                log INFO "Waiting for firewall to attach (attempt $i/$ATTACH_WAIT_RETRIES)..."
                sleep "$ATTACH_WAIT_DELAY"
            fi
        done
        if [[ "$ATTACH_CONFIRMED" != true ]]; then
            log ERROR "Firewall did not attach within expected time for Linode ID $LINODE_ID"
            sleep infinity
        fi
    else
        log ERROR "Failed to attach firewall to Linode ID $LINODE_ID. Sleeping indefinitely to avoid container restart loop."
        sleep infinity
    fi
}

get_current_interfaces() {
  wait_for_dns
  linode-cli linodes config-view "$LINODE_ID" "$CONFIG_ID" --json | jq '.[0].interfaces'
}

build_base_interfaces() {
  local current="$1"
  local cluster="${LKE_CLUSTER_TYPE,,}"

  if ! echo "$current" | jq -e 'type=="array"' >/dev/null 2>&1; then
    log ERROR "build_base_interfaces: current is not a JSON array"
    return 9
  fi

  local len
  len="$(echo "$current" | jq 'length')"

  # NOTE: this function is called specifically from the "VLAN is already
  # attached, now also attaching VPC" path (attach_vpc_interface_only()).
  # It previously only ever extracted vpc/public from the current
  # interfaces, so an already-attached VLAN interface was silently dropped
  # from the "base" it returned - meaning adding VPC to a node that already
  # had VLAN working would strip VLAN out as a side effect. Preserve it if
  # present, same principle as the VPC-preservation fix in
  # configure_interfaces().
  local existing_vlan
  existing_vlan="$(echo "$current" | jq -c '[.[] | select(.purpose=="vlan")] | .[0] // empty')"

  if [[ "$cluster" == "enterprise" ]]; then
    local vpc_obj public_obj
    vpc_obj="$(echo "$current"  | jq -c '[.[] | select(.purpose=="vpc")]    | .[0] // empty')"
    public_obj="$(echo "$current"| jq -c '[.[] | select(.purpose=="public")] | .[0] // empty')"

    if [[ -z "$vpc_obj" || -z "$public_obj" ]]; then
      log ERROR "Enterprise base interfaces not detected (need both vpc and public). current=$current"
      return 10
    fi

    # Enterprise fixed base order: VPC (eth0), Public (eth1), then VLAN
    # (eth2+) if already attached - VLAN always goes at the next available
    # index after the fixed VPC+Public base, never reordering them.
    jq -nc --argjson vpc "$vpc_obj" --argjson pub "$public_obj" --argjson vlan "${existing_vlan:-null}" \
      '[$vpc, $pub] + (if $vlan == null then [] else [$vlan] end)'
    return 0
  fi

  # Standard LKE
  if [[ "$len" -eq 0 ]]; then
    log WARN "Standard LKE: config-view returned empty interfaces; assuming implicit public exists."
    jq -nc --argjson vlan "${existing_vlan:-null}" \
      '[ { "purpose": "public" } ] + (if $vlan == null then [] else [$vlan] end)'
    return 0
  fi

  local public_obj
  public_obj="$(echo "$current" | jq -c '[.[] | select(.purpose=="public")] | .[0] // empty')"
  if [[ -z "$public_obj" ]]; then
    log ERROR "Standard base public interface not detected. current=$current"
    return 11
  fi

  # Standard base order: Public (eth0), then VLAN (eth1) if already attached
  # - the caller appends the new VPC after this, giving the desired final
  # order Public, VLAN, VPC.
  jq -nc --argjson pub "$public_obj" --argjson vlan "${existing_vlan:-null}" \
    '[$pub] + (if $vlan == null then [] else [$vlan] end)'
}

configure_interfaces() {

  log INFO "Determining desired interface configuration (explicit desired-state build)..."

  local want_vlan="${ENABLE_VLAN,,}"
  local want_vpc="${ENABLE_VPC_INTERFACE,,}"
  local cluster_type="${LKE_CLUSTER_TYPE,,}"

  wait_for_dns

  CONFIG_ID=$(linode-cli linodes configs-list "$LINODE_ID" --json | jq -r '.[0].id')
  if [[ -z "$CONFIG_ID" ]]; then
    log ERROR "Unable to determine active config ID."
    return 20
  fi

  cfg_json=$(linode-cli linodes config-view "$LINODE_ID" "$CONFIG_ID" --json | jq '.[0]')
  current_interfaces=$(echo "$cfg_json" | jq -c '.interfaces // []')

  log INFO "==== CURRENT INTERFACES ===="
  echo "$current_interfaces" | jq .

  # ------------------------------------------------------------
  # Extract existing objects (if present)
  # ------------------------------------------------------------

  public_obj=$(echo "$current_interfaces" | jq -c '[.[] | select(.purpose=="public")] | .[0] // empty')
  existing_vpc=$(echo "$current_interfaces" | jq -c '[.[] | select(.purpose=="vpc")] | .[0] // empty')
  existing_vlan=$(echo "$current_interfaces" | jq -c '[.[] | select(.purpose=="vlan")] | .[0] // empty')

  # Public must always exist
  if [[ -z "$public_obj" ]]; then
      public_obj='{"purpose":"public"}'
  fi

  # ------------------------------------------------------------
  # Build VLAN (ONLY if requested)
  # ------------------------------------------------------------

  vlan_obj=""
  if [[ "$want_vlan" == "true" ]]; then
      if [[ -n "$existing_vlan" ]]; then
          vlan_obj="$existing_vlan"
      else
          if [[ -z "$VLAN_LABEL" || -z "$IP_ADDRESS" ]]; then
              log ERROR "VLAN requested but VLAN_LABEL or IP_ADDRESS missing."
              return 12
          fi
          vlan_obj=$(jq -nc \
              --arg vlan "$VLAN_LABEL" \
              --arg ip "$IP_ADDRESS" \
              '{purpose:"vlan", label:$vlan, ipam_address:$ip}')
      fi
  fi

  # ------------------------------------------------------------
  # Build VPC (create ONLY if requested; otherwise preserve, never remove)
  # ------------------------------------------------------------
  # NOTE: ENABLE_VPC_INTERFACE=false means "don't actively manage/create a
  # VPC interface" - it does NOT mean "strip out a VPC interface that's
  # already attached for some other reason." Previously, when this flag was
  # false, vpc_obj stayed empty unconditionally, so any pre-existing VPC
  # interface was silently dropped from the desired state and removed the
  # next time this node's config was rewritten (e.g. to attach VLAN) -
  # even though nothing about attaching VLAN should have touched VPC at
  # all. Now: only the *creation* of a brand-new VPC interface is gated
  # behind want_vpc; an already-attached one is always preserved as-is.

  vpc_obj=""
  if [[ -n "$existing_vpc" ]]; then
      vpc_obj="$existing_vpc"
      if [[ "$want_vpc" != "true" ]]; then
          log INFO "ENABLE_VPC_INTERFACE=false but a VPC interface is already attached - preserving it as-is (unmanaged, not removed)."
      fi
  elif [[ "$want_vpc" == "true" ]]; then
      if [[ -z "$VPC_SUBNET_ID" ]]; then
          log ERROR "VPC requested but VPC_SUBNET_ID missing."
          return 13
      fi
      vpc_obj=$(jq -nc \
              --argjson subnet "$VPC_SUBNET_ID" \
              '{purpose:"vpc", subnet_id:$subnet}')
  fi

  # ------------------------------------------------------------
  # EXPLICIT ORDER BUILD
  # ------------------------------------------------------------

  if [[ "$cluster_type" == "enterprise" ]]; then
      # Enterprise → VPC → PUBLIC → VLAN
      updated_interfaces=$(jq -nc \
          --argjson vpc "${vpc_obj:-null}" \
          --argjson pub "$public_obj" \
          --argjson vlan "${vlan_obj:-null}" \
          '(
              (if $vpc  == null then [] else [$vpc] end)
              + [$pub]
              + (if $vlan == null then [] else [$vlan] end)
           )')
  else
      # Standard → PUBLIC → VLAN → VPC
      updated_interfaces=$(jq -nc \
          --argjson pub "$public_obj" \
          --argjson vlan "${vlan_obj:-null}" \
          --argjson vpc "${vpc_obj:-null}" \
          '(
              [$pub]
              + (if $vlan == null then [] else [$vlan] end)
              + (if $vpc  == null then [] else [$vpc] end)
           )')
  fi

  log INFO "==== UPDATED INTERFACES (STRICT DESIRED ORDER) ===="
  echo "$updated_interfaces" | jq .

  # ------------------------------------------------------------
  # Write desired state to etcd
  # ------------------------------------------------------------

  DESIRED_JSON=$(jq -n \
      --arg linode_id "$LINODE_ID" \
      --arg current_config_id "$CONFIG_ID" \
      --argjson interfaces "$updated_interfaces" \
      '{
        linode_id: ($linode_id|tonumber),
        current_config_id: ($current_config_id|tonumber),
        interfaces: $interfaces,
        status: "pending"
      }')

  DESIRED_KEY="/vlan-config/${LINODE_ID}"
  log INFO "==== DESIRED_KEY is DESIRED_KEY='$DESIRED_KEY' ===="
  if [[ -z "${ETCD_ENDPOINTS:-}" ]]; then
    log ERROR "ETCD_ENDPOINTS is not set. Cannot store desired config. Aborting."
    exit 1
  fi
  ETCD_PRIMARY=$(get_etcd_leader_endpoint)
  if [[ -z "$ETCD_PRIMARY" ]]; then
    log ERROR "ETCD_PRIMARY derived from ETCD_ENDPOINTS is empty. ETCD_ENDPOINTS='$ETCD_ENDPOINTS'"
    exit 1
  fi

  # NOTE: GNU base64 wraps output at 76 chars by default, inserting literal
  # newlines into the encoded string. DESIRED_JSON (the full interfaces
  # payload) is well over 76 chars, so without -w 0 its base64 encoding spans
  # multiple lines - and those raw newlines land inside a JSON string literal
  # in the curl -d payload below, which etcd's gRPC-gateway rejects with
  # "invalid character '\n' in string literal" (HTTP 400). Always use -w 0.
  set +e
  RESP="$(curl -sS -w "\nCURL_EXIT=%{exitcode}\nHTTP=%{http_code}\n" \
    -X POST "${ETCD_PRIMARY}/v3/kv/put" \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"$(echo -n "$DESIRED_KEY" | base64 -w 0)\",\"value\":\"$(echo -n "$DESIRED_JSON" | base64 -w 0)\"}")"
  RC=$?
  set -e

  # NOTE: previously this only checked for a total connection failure (RC != 0
  # or HTTP=000). Any *other* non-200 response (e.g. a transient 503/timeout
  # from etcd during a leader election or DNS blip) still passed this check,
  # logged a false "stored in etcd" success, and proceeded straight to
  # shutdown with no durable job actually written - stranding the node
  # offline forever with nothing for the controller to reconcile. Require an
  # explicit HTTP=200 instead of just "not a total failure".
  HTTP_CODE="$(echo "$RESP" | grep -oE 'HTTP=[0-9]+' | cut -d= -f2)"

  if [[ $RC -ne 0 || "$HTTP_CODE" != "200" ]]; then
    log ERROR "Failed to write desired config to etcd via ${ETCD_PRIMARY} (curl_rc=$RC, http=$HTTP_CODE). Response:"
    echo "$RESP"
    exit 1
  fi

  # Read-back verification: don't trust a 200 alone - confirm etcd actually
  # durably holds exactly the value we just wrote before we ever shut this
  # node down. If this doesn't match, abort rather than shutting down with
  # no recoverable job (the DaemonSet will simply retry this function on its
  # next run once etcd is healthy again).
  log INFO "Verifying etcd write via read-back..."
  EXPECTED_VALUE_B64="$(echo -n "$DESIRED_JSON" | base64 -w 0)"

  set +e
  VERIFY_RESP="$(curl -sS -X POST "${ETCD_PRIMARY}/v3/kv/range" \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"$(echo -n "$DESIRED_KEY" | base64 -w 0)\"}")"
  set -e

  VERIFY_VALUE_B64="$(echo "$VERIFY_RESP" | jq -r '.kvs[0].value // empty')"

  if [[ "$VERIFY_VALUE_B64" != "$EXPECTED_VALUE_B64" ]]; then
    log ERROR "etcd read-back verification failed - write did not durably commit. Aborting (no shutdown)."
    log INFO "Verify response: $VERIFY_RESP"
    exit 1
  fi

  log INFO "Desired config stored in etcd (verified via read-back)."
  log INFO "Initiating shutdown. Controller will reconcile."
  serialized_shutdown
  exit 0
}

# === VLAN Ready Label + Taint Helpers ===
# Scheduling is gated by TWO independent layers, not one:
#
#   1. The "vlan-not-ready" node taint, declared permanently in the app
#      pool's LKE config (see docs/DAY2-OPERATIONS.md "Applying the
#      vlan-not-ready taint"). We do NOT try to remove this taint anymore -
#      LKE treats pool-level taints as ongoing desired state and reconciles
#      them back onto every node in the pool indefinitely, even nodes that
#      already finished VLAN attach (confirmed empirically: a taint cleared
#      via kubectl reappeared on already-ready nodes with no trigger from
#      our own code). Fighting that reconciliation is a losing, pointless
#      battle, so we've stopped: the taint now just permanently means "you
#      must be a workload that knows about this pool" - a static membership
#      check, not a readiness signal. Only vlan-manager itself carries an
#      unconditional toleration for it (see
#      manifests/07-vlan-manager-daemonset.yaml); everything else that needs
#      to run here gets its toleration injected by the Kyverno policy below.
#
#   2. The vlan-ready=true node LABEL (set by this function, read nowhere
#      but by us) is the actual dynamic readiness signal. It's the target of
#      manifests/09-kyverno-vlan-ready-policy.yaml, which mutates every
#      non-system pod to require `nodeSelector: vlan-ready: "true"` and to
#      tolerate the permanent taint. Kyverno owns this instead of a second
#      hand-rolled node taint because a plain "vlan-ready" nodeSelector key
#      is a map entry, not a list entry like the old nodeAffinity
#      nodeSelectorTerms field was - so a second, independent project's
#      Kyverno policy adding its own different key (e.g. acl-ready) to the
#      same nodeSelector map can never collide with this one, regardless of
#      install order. That's the fix for the original bug (two Kyverno
#      policies silently overwriting each other's nodeSelectorTerms patch).
VLAN_NOT_READY_TAINT_KEY="vlan-not-ready"
VLAN_NOT_READY_TAINT_EFFECT="NoSchedule"

mark_node_vlan_ready() {
    log INFO "Marking node '$NODE_NAME' as vlan-ready=true..."
    kubectl label node "$NODE_NAME" vlan-ready=true --overwrite
    log INFO "Node label applied: vlan-ready=true (Kyverno's nodeSelector gate now allows app pods here; we deliberately do NOT touch the '${VLAN_NOT_READY_TAINT_KEY}' taint - see comment block above)."

    # NAT fleet sidecar handoff: write the confirmed VLAN interface name and
    # touch a readiness marker on the shared emptyDir volume (see
    # manifests/07-vlan-manager-daemonset.yaml's nat-fleet-agent container
    # and scripts/12-nat-fleet-agent-entrypoint.sh), so the sidecar knows
    # which interface to run client-agent against and when it's safe to
    # start. Folded in here - once, covering all three of this function's
    # call sites - rather than duplicated at each one, same reasoning as
    # clear_scale_down_disabled() below. Harmless no-op if
    # NAT_FLEET_HANDOFF_DIR isn't set (older DaemonSet spec) or if this
    # mode has no VLAN interface at all (no-network/VPC-only modes) - the
    # sidecar only ever acts on this when ENABLE_NAT_FLEET is "true", and
    # that mode requires a VLAN interface to mean anything.
    if [[ -n "${NAT_FLEET_HANDOFF_DIR:-}" ]]; then
        local NAT_FLEET_IFACE
        NAT_FLEET_IFACE=$(get_vlan_interface_name 2>/dev/null || true)
        if [[ -n "$NAT_FLEET_IFACE" ]]; then
            mkdir -p "$NAT_FLEET_HANDOFF_DIR"
            echo "$NAT_FLEET_IFACE" > "${NAT_FLEET_HANDOFF_DIR}/vlan-iface"
            touch "${NAT_FLEET_HANDOFF_DIR}/vlan-ready"
            log INFO "NAT fleet handoff: wrote interface '$NAT_FLEET_IFACE' to ${NAT_FLEET_HANDOFF_DIR}/vlan-iface."
        else
            log INFO "NAT fleet handoff: no VLAN interface detected in this mode - skipping handoff file write (harmless unless ENABLE_NAT_FLEET=true, which requires a VLAN interface)."
        fi
    fi

    # Re-enable cluster-autoscaler scale-down now that this node is
    # actually usable - see disable_scale_down_during_onboarding() for why
    # this was disabled in the first place. Folded into this function
    # (rather than added at each of its call sites) since every path that
    # reaches "vlan-ready" already calls mark_node_vlan_ready exactly once.
    clear_scale_down_disabled
}

clear_node_vlan_ready_label() {
    # Dead code today (nothing calls this), kept for symmetry. Only clears
    # the label - the taint is permanent pool-level config now, not
    # something this script adds or removes on either transition.
    log INFO "Clearing node '$NODE_NAME' vlan-ready label (blocks app scheduling again via Kyverno's nodeSelector requirement)..."
    kubectl label node "$NODE_NAME" vlan-ready- 2>/dev/null || true
}

# === Cluster-Autoscaler Scale-Down Protection Helpers ===
# A node that's still mid-onboarding (VLAN/VPC not yet attached) has no
# workload pods on it, because the "vlan-not-ready" taint blocks real pods
# from scheduling there until it's removed by mark_node_vlan_ready() above.
# Cluster-autoscaler's own idle-node detection has no idea WHY the node has
# no pods - it just sees an "idle" node and may pick it as a scale-down
# candidate, potentially removing a node that's already partway through (or
# about to start) its VLAN attachment cycle. That would waste the entire
# onboarding cost and make an already-slow scale-up even slower on the next
# attempt. Disabling scale-down for the duration of onboarding, then
# re-enabling it once the node is actually vlan-ready, closes that window.
disable_scale_down_during_onboarding() {
    log INFO "Disabling cluster-autoscaler scale-down for node '$NODE_NAME' while VLAN/VPC onboarding is in progress..."
    kubectl annotate node "$NODE_NAME" cluster-autoscaler.kubernetes.io/scale-down-disabled=true --overwrite 2>/dev/null || \
        log WARN "Failed to set scale-down-disabled annotation on '$NODE_NAME' - continuing anyway (non-fatal)."
}

clear_scale_down_disabled() {
    log INFO "Re-enabling cluster-autoscaler scale-down for node '$NODE_NAME' (onboarding complete)..."
    kubectl annotate node "$NODE_NAME" cluster-autoscaler.kubernetes.io/scale-down-disabled- 2>/dev/null || true
}

# ------------------------------------------------------------
# Test seam: lets tests/bash `source` this script and call its functions
# directly (e.g. build_base_interfaces, configure_interfaces,
# get_vlan_interface_name) without running the main logic below, which
# talks to the real node/Linode/Kubernetes/etcd. Unset in every real
# deployment - the container always execs this script directly, never
# sources it - so this is a no-op there. See tests/README.md.
# ------------------------------------------------------------
if [[ "${SOURCE_ONLY_FOR_TESTS:-false}" == "true" ]]; then
  return 0 2>/dev/null || exit 0
fi

# === Discover Node Name ===
# Prefer the Downward API (NODE_NAME env var, spec.nodeName - see the
# DaemonSet manifest) over deriving it from `ip route get 8.8.8.8`'s src
# address. That address stops being a reliable stand-in for "this node's
# identity" the moment ENABLE_NAT_GATEWAY (or any ROUTE_LIST default-route
# change) is active - confirmed live: once the default route pointed at a
# NAT gateway over the VLAN, this same command returned the node's VLAN IP
# instead of its real primary IP, which is never in `status.addresses`, so
# the old kubectl-match-by-IP lookup below came up empty on every
# subsequent pod restart. See docs/NAT-Test.md for the live repro.
if [[ -n "${NODE_NAME:-}" ]]; then
    log INFO "Using NODE_NAME from the Downward API: $NODE_NAME"
else
    log INFO "NODE_NAME not provided via the Downward API - falling back to route-based self-IP detection (see DaemonSet manifest to add it)..."
    log INFO "Fetching NODE IP of the instance..."
    NODE_IP=$(ip route get 8.8.8.8 | awk '{print $7}')
    log INFO "Node IP: $NODE_IP"

    log INFO "Fetching NODE NAME of the instance..."
    NODE_NAME=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.addresses[]?.address == "'"$NODE_IP"'") | .metadata.name')
fi
log INFO "Node Name: $NODE_NAME"

if [[ -z "$NODE_NAME" ]]; then
    log ERROR "Could not determine this pod's node name. Exiting to allow pod restart."
    exit 1
fi

# Disable autoscaler scale-down as early as possible - every run of this
# script starts from "not known to be ready yet," and re-running this on
# every container restart is intentional/harmless: it's just re-asserting
# the same annotation until mark_node_vlan_ready() clears it further down.
disable_scale_down_during_onboarding

# === Fetch Public IP of the Node ===
log INFO "Fetching Public IP of the instance..."
PUBLIC_IP=$(kubectl get node $NODE_NAME -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}' | awk {'print $1'})
log INFO "Public IP of the Node: $PUBLIC_IP"

export LINODE_CLI_CONFIG="/root/.linode-cli/linode-cli"

# === Discover Linode ID and Configuration ID ===
log INFO "Finding Linode ID for Public IP: $PUBLIC_IP"
LINODE_ID=""
TARGET_IP="$PUBLIC_IP"

page=1
while true; do
    log INFO "Searching Linode list: Page $page"
    wait_for_dns

    result=$(linode-cli linodes list --page $page --page-size 100 --json)

    if [[ $(echo "$result" | jq 'length') -eq 0 ]]; then
        break
    fi

    LINODE_ID=$(echo "$result" | jq -r --arg ip "$TARGET_IP" '.[] | select(.ipv4[]? == $ip) | .id')

    if [[ -n "$LINODE_ID" ]]; then
        log INFO "Found Linode with IP $TARGET_IP. LINODE_ID: $LINODE_ID"
        break
    fi

    page=$((page + 1))
done

if [[ -z "$LINODE_ID" ]]; then
    log ERROR "Failed to find Linode with public IP $TARGET_IP."
    exit 1
fi

wait_for_dns
CONFIG_ID=$(linode-cli linodes configs-list "$LINODE_ID" --json | jq -r '.[0].id')

if [ -z "$CONFIG_ID" ]; then
    log ERROR "Failed to retrieve configuration ID for Linode ID $LINODE_ID"
    exit 1
fi

log INFO "Linode ID: $LINODE_ID, Config ID: $CONFIG_ID"

# === Main Logic ===

# Cleanup old CoreDNS reboot lock if held by this node
REBOOT_LOCK_KEY="/coredns-reboot-lock"
CURRENT_NODE=$(hostname)
ETCD_PRIMARY="$(get_etcd_leader_endpoint)"
ETCD_PRIMARY_DNS=$(echo "$ETCD_PRIMARY" | sed -e 's|http://||g' -e 's|:2379||g')
if [ -n "$ETCD_ENDPOINTS" ]; then
    # Wait for etcd DNS to resolve
    until nslookup $ETCD_PRIMARY_DNS >/dev/null 2>&1; do
        log INFO "Waiting for DNS to resolve $ETCD_PRIMARY_DNS during lock cleanup..."
        sleep 5
    done

    # Check and delete the lock if this node owns it
    LOCK_OWNER=$(etcdctl --endpoints "$ETCD_PRIMARY" get "$REBOOT_LOCK_KEY" --print-value-only 2>/dev/null)
    if [[ "$LOCK_OWNER" == "$CURRENT_NODE" ]]; then
        etcdctl --endpoints "$ETCD_ENDPOINTS" del "$REBOOT_LOCK_KEY"
        log INFO "Removed stale CoreDNS reboot lock held by $CURRENT_NODE"
    fi
fi

##############################################
# Networking Mode Resolution
##############################################

ENABLE_VLAN_L=$(echo "${ENABLE_VLAN:-false}" | tr '[:upper:]' '[:lower:]')
ENABLE_VPC_L=$(echo "${ENABLE_VPC_INTERFACE:-false}" | tr '[:upper:]' '[:lower:]')

# NAT-egress modes are mutually exclusive: a single customer-operated NAT
# gateway instance (ENABLE_NAT_GATEWAY, see push_nat_gateway_route() below)
# and an HA/ECMP linode-nat-gateway fleet (ENABLE_NAT_FLEET, handled by the
# nat-fleet-agent sidecar - see manifests/07-vlan-manager-daemonset.yaml and
# scripts/12-nat-fleet-agent-entrypoint.sh) can't both manage this node's
# default route at once. Checked here, early, alongside the other
# networking-mode env resolution, rather than deep inside either code path.
ENABLE_NAT_GATEWAY_LC=$(echo "${ENABLE_NAT_GATEWAY:-false}" | tr '[:upper:]' '[:lower:]')
ENABLE_NAT_FLEET_LC=$(echo "${ENABLE_NAT_FLEET:-false}" | tr '[:upper:]' '[:lower:]')
if [[ "$ENABLE_NAT_GATEWAY_LC" == "true" && "$ENABLE_NAT_FLEET_LC" == "true" ]]; then
    log ERROR "ENABLE_NAT_GATEWAY and ENABLE_NAT_FLEET are both \"true\" - these are mutually exclusive NAT-egress modes (single-node vs. HA fleet). Set only one. Sleeping indefinitely to avoid container crash loop..."
    sleep infinity
fi

if [[ "$ENABLE_NAT_FLEET_LC" == "true" ]]; then
    # client-agent (running in the nat-fleet-agent sidecar) tries to set this
    # itself at its own startup - but that container only has
    # capabilities.add: ["NET_ADMIN"], not privileged: true (see
    # manifests/07-vlan-manager-daemonset.yaml), and /proc/sys is mounted
    # read-only for any non-privileged container regardless of which
    # capabilities it holds. Confirmed live: client-agent logs "[Errno 30]
    # Read-only file system" trying to write this itself, then proceeds
    # anyway with the wrong hash policy still in effect. This container IS
    # privileged, so set it here instead, defensively - the same fix
    # HANDOVER.md §4 documents for anyone reimplementing ECMP routing
    # themselves, just applied as a fallback for the bundled-binary approach
    # too rather than assumed to always work from inside client-agent's own
    # container. Without this, ECMP nexthop selection hashes on
    # source+destination IP only (kernel default, policy 0) - repeated
    # traffic to the same external destination concentrates on one fleet
    # node instead of spreading, confirmed live via repeated curl to the
    # same external IP always returning the same NAT node's public IP.
    # Runtime-only (not persisted to a host sysctl.d file - this container
    # has no access to the host filesystem for that) - safe, because this
    # script already re-runs and re-asserts idempotent state like this on
    # every container restart, including the one right after every reboot
    # this repo's own shutdown/reconfigure/boot cycle causes.
    if sysctl -w net.ipv4.fib_multipath_hash_policy=1 >/dev/null 2>&1; then
        log INFO "Set net.ipv4.fib_multipath_hash_policy=1 for NAT fleet ECMP (defensive fallback - client-agent's own attempt fails from its own container, see comment above)."
    else
        log WARN "Failed to set net.ipv4.fib_multipath_hash_policy=1 - NAT fleet ECMP may concentrate traffic on fewer nodes than expected for repeated destinations."
    fi
fi

# --------------------------------------------------
# MODE 1: No VLAN and No VPC Requested
# --------------------------------------------------
if [[ "$ENABLE_VLAN_L" != "true" && "$ENABLE_VPC_L" != "true" ]]; then
    log INFO "No VLAN or VPC requested. Nothing to configure."

    # Optional firewall (still allowed even if no VLAN/VPC)
    if [[ "${ENABLE_FIREWALL,,}" == "true" ]]; then
        log INFO "Attaching Linode Firewall..."
        create_and_attach_firewall
    fi

    log INFO "Marking node as vlan-ready=true"
    mark_node_vlan_ready

    log INFO "No-network mode completed successfully."
    sleep infinity
fi

# --------------------------------------------------
# MODE 2: VPC-ONLY MODE (ENABLE_VLAN=false, ENABLE_VPC=true)
# --------------------------------------------------
if [[ "$ENABLE_VLAN_L" != "true" && "$ENABLE_VPC_L" == "true" ]]; then
    log INFO "Running in VPC-only mode (NO VLAN allocation / NO VLAN config-update)"

    log INFO "Checking VPC interface state..."

    set +e
    attach_vpc_interface_only
    RESULT=$?
    set -e

    case "$RESULT" in
        2)
            log INFO "VPC interface added. Initiating serialized shutdown for controller reconciliation..."
            serialized_shutdown
            log INFO "Shutdown initiated. Exiting cleanly."
            exit 0
            ;;
        0)
            log INFO "VPC already attached. No shutdown required."
            ;;
        *)
            log ERROR "VPC attach failed with rc=$RESULT. Exiting to avoid loop."
            exit 1
            ;;
    esac

    # Post-boot finalization
    if [[ "${ENABLE_FIREWALL,,}" == "true" ]]; then
        log INFO "Attaching Linode Firewall..."
        create_and_attach_firewall
    else
        log INFO "ENABLE_FIREWALL=false → Skipping firewall attachment"
    fi

    log INFO "Marking node as vlan-ready=true (VPC-only mode)"
    mark_node_vlan_ready

    log INFO "VPC-only mode completed successfully."
    sleep infinity
fi

# 1) Fix "configured but missing VLAN interface" first (ensures interface exists on OS)
handle_vlan_configured_but_missing_interface

# 2) Check current interface state
log INFO "Checking existing VLAN/VPC attachment state for Linode instance $LINODE_ID..."
VLAN_PRESENT=false
VPC_PRESENT=false

if is_vlan_attached; then
    VLAN_PRESENT=true
fi
if is_vpc_attached; then
    VPC_PRESENT=true
fi

log INFO "State summary: VLAN_PRESENT=${VLAN_PRESENT}, ENABLE_VPC_INTERFACE=${ENABLE_VPC_INTERFACE}, VPC_PRESENT=${VPC_PRESENT}"

# 2a) If VLAN is attached and VPC is either disabled or already attached => just do routes/firewall and iptables, no reboot
if [[ "$VLAN_PRESENT" == true && "$ENABLE_VPC_L" == "true" && "$VPC_PRESENT" == false ]]; then
    log INFO "VLAN is attached but VPC interface is missing. Attaching VPC and rebooting once..."
    set +e
    attach_vpc_interface_only
    RESULT=$?
    set -e
    if [[ "$RESULT" -eq 2 ]]; then
      log INFO "VPC attached now. Rebooting once..."
      serialized_shutdown
      sleep 300
      log WARN "Node did not reboot as expected after VPC attach. Sleeping to avoid loop."
      sleep infinity
    elif [[ "$RESULT" -eq 0 ]]; then
      log INFO "VPC already satisfied. No reboot needed."
    else
      log ERROR "VPC attach failed with rc=$RESULT. Sleeping to avoid loop."
      sleep infinity
    fi
fi

# 2b) VLAN attached and either:
#     - VPC is disabled (ENABLE_VPC_INTERFACE != true), OR
#     - VPC is already present
#     => No config-update, no reboot; just routes/firewall/iptables.
if [[ "$VLAN_PRESENT" == true ]]; then
    log INFO "VLAN is attached and VPC state is satisfied (either disabled or already present). Skipping config-update and reboot."
    push_route
    push_nat_gateway_route
    create_and_attach_firewall
    configure_vlan_ew_firewall
    # Unblock application scheduling only after success
    mark_node_vlan_ready
    log INFO "VLAN/VPC configuration and firewall complete. Sleeping indefinitely..."
    sleep infinity
fi

# 3) VLAN is not attached => allocate VLAN IP and build interfaces list (VLAN + optional VPC), then reboot ONCE
log ERROR "VLAN is not attached. Proceeding with VLAN (and optional VPC) configuration..."
MAX_RETRIES=5
RETRY_COUNT=0
SUCCESS=false

IP_ALLOCATE_ERR_FILE="/tmp/03-script-ip-allocate.stderr"

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    log INFO "Attempting to allocate IP address... (Attempt $((RETRY_COUNT+1))/$MAX_RETRIES)"

    # 03-script-ip-allocate.sh's log()/error() write to stderr, not stdout -
    # its stdout is the allocated IP and nothing else. Capturing stderr
    # separately (rather than losing it, or letting it mix into
    # $IP_ADDRESS1) is what lets us actually print the real reason below
    # instead of just "failed, retrying" - see docs/TROUBLESHOOTING.md.
    set +e
    IP_ADDRESS1=$(/tmp/03-script-ip-allocate.sh "$SUBNET" 2>"$IP_ALLOCATE_ERR_FILE")
    STATUS=$?
    set -e

    if [ $STATUS -eq 0 ] && [ -n "$IP_ADDRESS1" ]; then
        IP_ADDRESS="$IP_ADDRESS1"
        log INFO "Allocated IP address: $IP_ADDRESS"
        SUCCESS=true
        break
    else
        log ERROR "IP allocation attempt failed (exit=$STATUS). Reason:"
        if [ -s "$IP_ALLOCATE_ERR_FILE" ]; then
            while IFS= read -r ERR_LINE; do
                log INFO "$ERR_LINE"
            done < "$IP_ALLOCATE_ERR_FILE"
        else
            log INFO "(no diagnostic output captured)"
        fi
        log INFO "Retrying..."
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    sleep 5
done

rm -f "$IP_ALLOCATE_ERR_FILE"

if [ "$SUCCESS" = false ]; then
    log ERROR "IP allocation failed after $MAX_RETRIES attempts. Exiting to allow pod restart."
    exit 1
fi

# === Build interface JSON and updating the config===
log INFO "Building interface JSON and updating the config..."


# === Check VLAN is attached after attachment and then reboot ONCE ===
if ! is_vlan_attached; then
    log ERROR "VLAN is not attached. Proceeding with enterprise-safe configuration..."
    configure_interfaces
    exit 0
else
    log INFO "VLAN already attached. Continuing normal flow..."
fi

# === No EXIT-trap IP release here, deliberately ===
# This used to have a `trap cleanup EXIT` that called 04-script-ip-release.sh
# on the way out. Removed rather than fixed, for two reasons:
#   1) The case that actually matters - the underlying node being deleted or
#      crashing - can never reach it anyway: Kubernetes can only deliver
#      SIGTERM if the kubelet and node are still alive to deliver it, and by
#      the time a node is gone there's no process left to signal at all. No
#      trap-reliability fix changes that.
#   2) Even on an ordinary pod restart where a trap COULD fire (OOM-kill,
#      `kubectl delete pod`, etc. - not a real node teardown), the only
#      guard against a wrongful release was checking for /tmp/rebooting,
#      which is only ever set during this script's OWN self-triggered
#      reboot cycle. Any other restart cause would have released an IP that
#      was still legitimately attached and in use on that same node - a
#      latent correctness bug, not just a reliability gap.
# Actual orphaned-IP cleanup is handled correctly and safely at the cluster
# level by scripts/11-vlan-ip-reconciler.sh instead: it cross-checks etcd
# against Linode's real, current attachments and only releases an IP after
# confirming it twice, 15 minutes apart - see docs/DEPLOYMENT.md
# "VLAN IP pool reconciliation".

# Unblock application scheduling only after success
mark_node_vlan_ready

log INFO "VLAN Attachment completed successfully."
log INFO "Instance $LINODE_ID is now connected to VLAN $VLAN_LABEL with IP $IP_ADDRESS."
log INFO "VLAN, VPC (if enabled), Routes, Firewall, and VLAN-EW iptables configuration steps completed successfully."
log INFO "Script execution complete. Sleeping indefinitely..."
sleep infinity
