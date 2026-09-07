#!/bin/bash
# 11-vlan-ip-reconciler.sh
#
# Periodically reconciles etcd's "used VLAN IP" tracking against Linode's own
# real, current VLAN interface attachments, and releases any IP etcd thinks
# is used that Linode confirms nothing actually holds anymore.
#
# Why this exists
# ----------------
# Deleting or recycling a node (manually, via a crash, or via the cluster
# autoscaler) never releases the VLAN IP that node was allocated - nothing
# in vlan-manager/vlan-config-controller calls /release on node teardown.
# Every such event leaves a permanent orphan entry in etcd. Left unchecked,
# this silently shrinks the allocatable pool until it's fully exhausted -
# which is exactly what happened in production: a /24 SUBNET with only 4
# real attachments had all 254 usable addresses marked "used" in etcd,
# stalling every new node's VLAN attach indefinitely.
#
# Safety design (read before changing MIN_CONFIRM_AGE_SECONDS or the cap)
# -------------------------------------------------------------------------
# - An IP allocated to a node that has been shut down for its own config
#   update, but hasn't had that config-update applied by
#   vlan-config-controller yet, will correctly show as "used" in etcd while
#   NOT yet appearing in a live Linode scan (Linode's interfaces haven't
#   been updated yet). Treating that as orphaned and releasing it mid-cycle
#   would risk a duplicate IP allocation. To avoid this:
#     1) Any IP tied to a pending/processing job in /vlan-config/ is always
#        excluded from consideration, regardless of what the Linode scan
#        shows.
#     2) An IP must be seen as an orphan candidate across two separate runs,
#        at least MIN_CONFIRM_AGE_SECONDS apart, before it is actually
#        released. First sighting only records a candidate timestamp in
#        etcd; nothing is released on first sighting.
# - MAX_AUTO_RELEASE_PER_RUN caps how many IPs this script will release
#   automatically in a single pass. If confirmed orphans exceed that count,
#   none of them are auto-released and a loud log line is emitted instead -
#   releasing an unusually large batch at once is far more likely to mean a
#   bug in this script's own scan than a normal amount of node churn, and
#   auto-releasing through that blindly would make the failure mode worse,
#   not better.
# - This script only ever touches IPs inside the currently-configured
#   SUBNET. Older/unrelated ranges left over from a previous SUBNET value
#   are deliberately left alone - reconciling those is a separate, manual
#   decision, not something to automate blindly.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# © Linode-LKE-Private-Network | Developed by Sandip Gangdhar | 2025

set -uo pipefail

# LOG_LEVEL (env, default INFO) gates verbosity: DEBUG < INFO < WARN < ERROR.
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
  echo "[RECONCILER] [$level] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

: "${ETCD_ENDPOINTS:?ETCD_ENDPOINTS not set}"
: "${REGION:?REGION not set}"
: "${SUBNET:?SUBNET not set}"
: "${LINODE_API_KEY:?LINODE_API_KEY not set}"

VLAN_IP_API="${VLAN_IP_API:-http://vlan-ip-controller-service.kube-system.svc.cluster.local:8080}"
MIN_CONFIRM_AGE_SECONDS="${MIN_CONFIRM_AGE_SECONDS:-900}"    # 15 minutes
MAX_AUTO_RELEASE_PER_RUN="${MAX_AUTO_RELEASE_PER_RUN:-20}"
CANDIDATE_PREFIX="/vlan-ip-reconciler/candidate/"
JOB_PREFIX="/vlan-config/"

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

get_healthy_etcd() {
  IFS=',' read -ra EPS <<< "$ETCD_ENDPOINTS"
  for ep in "${EPS[@]}"; do
    if curl -fsS --max-time 2 "$ep/health" >/dev/null 2>&1; then
      echo "$ep"
      return 0
    fi
  done
  return 1
}

ip_in_subnet() {
  python3 -c "
import ipaddress, sys
try:
    ip = ipaddress.ip_address(sys.argv[1])
    net = ipaddress.ip_network(sys.argv[2], strict=False)
    sys.exit(0 if ip in net else 1)
except Exception:
    sys.exit(2)
" "$1" "$2" 2>/dev/null
}

# Mirrors reserved_set() in scripts/06-rest-api.py exactly (network address,
# broadcast address, first usable host) - those three are permanently
# marked "used" in etcd by 05-script-ip-list-initialize.sh so they can never
# be handed out by /allocate, but they never show up in a real Linode VLAN
# scan either (nothing is ever actually attached at those addresses). Without
# this check they show up as "orphan candidates" every single run forever -
# /release's own reserved-address guard stops them from ever actually being
# released, so this was never a correctness bug, just permanent log noise
# and wasted release attempts on every confirmed-candidate run. Confirmed
# live: reconciling a real cluster's SUBNET reported its network/gateway/
# broadcast addresses as confirmed orphans and attempted (and was correctly
# refused) to release all three, every time.
ip_is_reserved() {
  python3 -c "
import ipaddress, sys
try:
    ip = ipaddress.ip_address(sys.argv[1])
    net = ipaddress.ip_network(sys.argv[2], strict=False)
    reserved = {net.network_address, net.broadcast_address}
    hosts = list(net.hosts())
    if hosts:
        reserved.add(hosts[0])
    sys.exit(0 if ip in reserved else 1)
except Exception:
    sys.exit(2)
" "$1" "$2" 2>/dev/null
}

# ------------------------------------------------------------
# Test seam: lets tests/bash `source` this script and call its functions
# directly (e.g. ip_in_subnet, get_healthy_etcd) without running the main
# reconciliation pass below, which talks to the real etcd/Linode APIs.
# Unset in every real deployment - the CronJob always execs this script
# directly, never sources it - so this is a no-op there. See
# tests/README.md.
# ------------------------------------------------------------
if [[ "${SOURCE_ONLY_FOR_TESTS:-false}" == "true" ]]; then
  return 0 2>/dev/null || exit 0
fi

EP="$(get_healthy_etcd)"
if [[ -z "$EP" ]]; then
  log ERROR "No healthy etcd endpoint reachable. Exiting without making any changes."
  exit 1
fi

log INFO "Starting VLAN IP reconciliation pass (REGION=$REGION, SUBNET=$SUBNET)"

# ------------------------------------------------------------
# 1) etcd's view of "used" IPs, scoped to the current SUBNET only.
# ------------------------------------------------------------
ETCD_USED_JSON=$(curl -s --max-time 30 "$VLAN_IP_API/api/v1/vlan-ips")
if [[ -z "$ETCD_USED_JSON" ]]; then
  log ERROR "Failed to reach vlan-ip-controller's /api/v1/vlan-ips. Exiting without making any changes."
  exit 1
fi

ALL_ETCD_USED_IPS=()
while IFS= read -r ip; do
  [[ -n "$ip" ]] && ALL_ETCD_USED_IPS+=("$ip")
done < <(echo "$ETCD_USED_JSON" | jq -r '.ips[]?' 2>/dev/null | sort -u)

ETCD_USED_IPS=()
if (( ${#ALL_ETCD_USED_IPS[@]} > 0 )); then
  for ip in "${ALL_ETCD_USED_IPS[@]}"; do
    if ip_in_subnet "$ip" "$SUBNET" && ! ip_is_reserved "$ip" "$SUBNET"; then
      ETCD_USED_IPS+=("$ip")
    fi
  done
fi
log INFO "etcd tracks ${#ALL_ETCD_USED_IPS[@]} IP(s) as used in total; ${#ETCD_USED_IPS[@]} of those fall inside the current SUBNET ($SUBNET) and are reconcilable (excludes the network/gateway/broadcast addresses, which stay permanently \"used\" by design - see ip_is_reserved())."

# ------------------------------------------------------------
# 2) Linode's real ground truth for this region (same logic
#    vlan-ip-controller's own fetch_assigned_ips() uses server-side).
# ------------------------------------------------------------
log INFO "Scanning Linode account (region=$REGION) for real VLAN attachments - this can take a while on larger accounts..."
LINODE_REAL_IPS=()
while IFS= read -r ip; do
  [[ -n "$ip" ]] && LINODE_REAL_IPS+=("$ip")
done < <(
  linode-cli linodes list --json 2>/dev/null \
    | jq -r --arg region "$REGION" '.[] | select(.region==$region) | .id' \
    | while read -r id; do
        linode-cli linodes configs-list "$id" --json 2>/dev/null | jq -r '.[].id' | while read -r cid; do
          linode-cli linodes config-view "$id" "$cid" --json 2>/dev/null \
            | jq -r '.[0].interfaces[]? | select(.purpose=="vlan") | .ipam_address' \
            | cut -d'/' -f1
        done
      done | sort -u
)
log INFO "Linode reports ${#LINODE_REAL_IPS[@]} real VLAN attachment(s) in $REGION."

# ------------------------------------------------------------
# 3) IPs tied to an in-flight (pending/processing) job right now - never
#    treated as orphaned, regardless of what the Linode scan shows.
# ------------------------------------------------------------
JOBS_JSON=$(curl -s -X POST "$EP/v3/kv/range" \
  -H "Content-Type: application/json" \
  -d "{\"key\":\"$(b64 "$JOB_PREFIX")\",\"range_end\":\"$(b64 "/vlan-config0")\"}")

IN_FLIGHT_IPS=()
while IFS= read -r v64; do
  [[ -z "$v64" ]] && continue
  decoded="$(echo "$v64" | base64 -d 2>/dev/null)"
  [[ -z "$decoded" ]] && continue
  status="$(echo "$decoded" | jq -r '.status // empty' 2>/dev/null)"
  [[ "$status" != "pending" && "$status" != "processing" ]] && continue
  while IFS= read -r ip; do
    [[ -n "$ip" ]] && IN_FLIGHT_IPS+=("$ip")
  done < <(echo "$decoded" | jq -r '.interfaces[]? | select(.purpose=="vlan") | .ipam_address' 2>/dev/null | cut -d'/' -f1)
done < <(echo "$JOBS_JSON" | jq -r '.kvs[]?.value // empty' 2>/dev/null)

log INFO "${#IN_FLIGHT_IPS[@]} IP(s) tied to an in-flight job - excluded from consideration this run."

# ------------------------------------------------------------
# 4) Compute this run's orphan candidates.
# ------------------------------------------------------------
declare -A LINODE_REAL_SET IN_FLIGHT_SET
if (( ${#LINODE_REAL_IPS[@]} > 0 )); then
  for ip in "${LINODE_REAL_IPS[@]}"; do LINODE_REAL_SET["$ip"]=1; done
fi
if (( ${#IN_FLIGHT_IPS[@]} > 0 )); then
  for ip in "${IN_FLIGHT_IPS[@]}"; do IN_FLIGHT_SET["$ip"]=1; done
fi

CANDIDATES=()
if (( ${#ETCD_USED_IPS[@]} > 0 )); then
  for ip in "${ETCD_USED_IPS[@]}"; do
    if [[ -z "${LINODE_REAL_SET[$ip]:-}" && -z "${IN_FLIGHT_SET[$ip]:-}" ]]; then
      CANDIDATES+=("$ip")
    fi
  done
fi
log INFO "${#CANDIDATES[@]} orphan candidate(s) this run (before age-confirmation check)."

# ------------------------------------------------------------
# 5) Age-gate: an IP must have been seen as a candidate on a previous run,
#    at least MIN_CONFIRM_AGE_SECONDS ago, before we actually release it.
#    First sighting only records the timestamp.
# ------------------------------------------------------------
NOW_EPOCH=$(date +%s)
CONFIRMED_RELEASES=()
declare -A STILL_CANDIDATE

if (( ${#CANDIDATES[@]} > 0 )); then
  for ip in "${CANDIDATES[@]}"; do
    STILL_CANDIDATE["$ip"]=1
    CAND_KEY="${CANDIDATE_PREFIX}${ip}"
    CAND_KEY_B64="$(b64 "$CAND_KEY")"

    EXISTING_B64=$(curl -s -X POST "$EP/v3/kv/range" \
      -H "Content-Type: application/json" \
      -d "{\"key\":\"$CAND_KEY_B64\"}" | jq -r '.kvs[0].value // empty')

    if [[ -z "$EXISTING_B64" ]]; then
      curl -s -X POST "$EP/v3/kv/put" -H "Content-Type: application/json" \
        -d "{\"key\":\"$CAND_KEY_B64\",\"value\":\"$(b64 "$NOW_EPOCH")\"}" >/dev/null
      log INFO "First sighting of $ip as orphaned - will re-check on a future run before releasing."
      continue
    fi

    FIRST_SEEN="$(echo "$EXISTING_B64" | base64 -d 2>/dev/null)"
    [[ "$FIRST_SEEN" =~ ^[0-9]+$ ]] || FIRST_SEEN="$NOW_EPOCH"
    AGE=$(( NOW_EPOCH - FIRST_SEEN ))

    if (( AGE >= MIN_CONFIRM_AGE_SECONDS )); then
      CONFIRMED_RELEASES+=("$ip")
    else
      log INFO "$ip still within confirmation window (${AGE}s / ${MIN_CONFIRM_AGE_SECONDS}s) - not releasing yet."
    fi
  done
fi

# Self-heal: prune candidate-tracking keys for IPs no longer seen as
# orphaned this run (e.g. a false positive earlier, or the IP legitimately
# came back into use).
EXISTING_CANDIDATES_JSON=$(curl -s -X POST "$EP/v3/kv/range" \
  -H "Content-Type: application/json" \
  -d "{\"key\":\"$(b64 "$CANDIDATE_PREFIX")\",\"range_end\":\"$(b64 "/vlan-ip-reconciler/candidate0")\"}")

while IFS= read -r k64; do
  [[ -z "$k64" ]] && continue
  full_key="$(echo "$k64" | base64 -d 2>/dev/null)"
  ip="${full_key#"$CANDIDATE_PREFIX"}"
  if [[ -z "${STILL_CANDIDATE[$ip]:-}" ]]; then
    curl -s -X POST "$EP/v3/kv/deleterange" -H "Content-Type: application/json" \
      -d "{\"key\":\"$(b64 "$full_key")\"}" >/dev/null
    log INFO "$ip is no longer orphaned - cleared its candidate tracking key."
  fi
done < <(echo "$EXISTING_CANDIDATES_JSON" | jq -r '.kvs[]?.key // empty' 2>/dev/null)

# ------------------------------------------------------------
# 6) Release confirmed orphans, unless this run's count is above the
#    safety cap.
# ------------------------------------------------------------
if (( ${#CONFIRMED_RELEASES[@]} == 0 )); then
  log INFO "Nothing confirmed for release this run."
elif (( ${#CONFIRMED_RELEASES[@]} > MAX_AUTO_RELEASE_PER_RUN )); then
  log WARN "${#CONFIRMED_RELEASES[@]} IP(s) are confirmed orphaned this run - above the safety cap of $MAX_AUTO_RELEASE_PER_RUN. NOT auto-releasing any of them. This many at once is unusual and more likely means a scan/config problem than normal node churn - investigate manually before releasing (see docs/TROUBLESHOOTING.md)."
else
  for ip in "${CONFIRMED_RELEASES[@]}"; do
    log INFO "Releasing confirmed orphaned IP: $ip"
    RESP=$(curl -s -X POST "$VLAN_IP_API/release" \
      -H "Content-Type: application/json" \
      -d "{\"ip_address\": \"$ip\"}")
    log INFO "-> $RESP"
    curl -s -X POST "$EP/v3/kv/deleterange" -H "Content-Type: application/json" \
      -d "{\"key\":\"$(b64 "${CANDIDATE_PREFIX}${ip}")\"}" >/dev/null
  done
fi

log INFO "Reconciliation pass complete."
