#!/bin/bash
# 12-nat-fleet-agent-entrypoint.sh
#
# Entrypoint for the "nat-fleet-agent" sidecar container in
# manifests/07-vlan-manager-daemonset.yaml. Runs alongside the main
# vlan-manager container in the same pod (shares hostNetwork) and, when
# ENABLE_NAT_FLEET is "true", launches the real client-agent binary (bundled
# into this image at build time - see manifests/Dockerfile) so this node's
# internet-bound traffic gets ECMP-routed across a linode-nat-gateway fleet
# instead of a single static NAT gateway instance.
#
# Why a separate container instead of a background process inside
# 02-script-vlan-attach.sh: this repo has a real history of bugs caused by
# hand-rolled process lifecycle management inside one bash entrypoint
# (serialized_shutdown's etcd-lock-leak saga, a set -e-in-subshell bug that
# killed vlan-config-controller, an over-eager EXIT trap). A separate
# container gets kubelet-native crash-restart and SIGTERM delivery for free,
# scoped to just this process, instead of needing hand-written supervision
# and signal-forwarding around a backgrounded child.
#
# Always deployed (this script always runs), matching this repo's
# "always-present, runtime-checked" convention for optional features
# (ENABLE_FIREWALL, ENABLE_VLAN_EW_FIREWALL): if ENABLE_NAT_FLEET isn't
# "true", this just idles forever below and never launches client-agent.
#
# Interface handoff: 02-script-vlan-attach.sh's mark_node_vlan_ready()
# writes the confirmed VLAN interface name to
# ${NAT_FLEET_HANDOFF_DIR}/vlan-iface and touches
# ${NAT_FLEET_HANDOFF_DIR}/vlan-ready on a shared emptyDir volume once it's
# actually confirmed the interface is up - this script blocks on that file
# rather than re-deriving the interface name itself, so there's exactly one
# place in this repo that knows how to detect the VLAN interface
# (get_vlan_interface_name), not two independent implementations that could
# disagree.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# © Linode-LKE-Private-Network | Developed by Sandip Gangdhar | 2025

set -uo pipefail

# LOG_LEVEL (env, default INFO) gates verbosity: DEBUG < INFO < WARN < ERROR.
# Same case-statement convention as every other script's log() - see
# CLAUDE.md "Logging" for why this is a case statement, not an associative
# array (this script isn't run under GNU parallel, but keeping the same
# shape across every script in this repo is worth more than a marginal
# simplification here).
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
  echo "[NAT-FLEET-AGENT] [$level] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

ENABLE_NAT_FLEET_LC="$(echo "${ENABLE_NAT_FLEET:-false}" | tr '[:upper:]' '[:lower:]')"

if [[ "$ENABLE_NAT_FLEET_LC" != "true" ]]; then
    log INFO "ENABLE_NAT_FLEET is not 'true' - idling. Nothing to do."
    sleep infinity
fi

if [[ -z "${NAT_FLEET_ROSTER_URL:-}" ]]; then
    log ERROR "ENABLE_NAT_FLEET is true but NAT_FLEET_ROSTER_URL is unset. Sleeping indefinitely to avoid container crash loop..."
    sleep infinity
fi

NAT_FLEET_HANDOFF_DIR="${NAT_FLEET_HANDOFF_DIR:-/var/run/nat-fleet}"
READY_MARKER="${NAT_FLEET_HANDOFF_DIR}/vlan-ready"
IFACE_FILE="${NAT_FLEET_HANDOFF_DIR}/vlan-iface"

log INFO "Waiting for vlan-manager to confirm the VLAN interface (watching ${READY_MARKER})..."
WAIT_ITER=0
while [[ ! -f "$READY_MARKER" ]]; do
    if (( WAIT_ITER % 12 == 0 )); then
        log INFO "Still waiting for vlan-manager readiness marker..."
    fi
    WAIT_ITER=$((WAIT_ITER + 1))
    sleep 5
done

if [[ ! -s "$IFACE_FILE" ]]; then
    log ERROR "Readiness marker present but ${IFACE_FILE} is missing/empty - vlan-manager may not have detected a VLAN interface in this mode. Sleeping indefinitely to avoid container crash loop..."
    sleep infinity
fi

LNG_PRIVATE_IFACE="$(cat "$IFACE_FILE")"
log INFO "VLAN interface confirmed: $LNG_PRIVATE_IFACE"

export NATCTL_ROSTER_URL="$NAT_FLEET_ROSTER_URL"
export LNG_PRIVATE_IFACE

if [[ -n "${NAT_FLEET_FALLBACK_PROBE_ENABLED:-}" ]]; then
    export LNG_FALLBACK_PROBE_ENABLED="$NAT_FLEET_FALLBACK_PROBE_ENABLED"
fi
if [[ -n "${NAT_FLEET_FALLBACK_PROBE_INTERVAL:-}" ]]; then
    export LNG_FALLBACK_PROBE_INTERVAL="$NAT_FLEET_FALLBACK_PROBE_INTERVAL"
fi
if [[ -n "${NAT_FLEET_HEALTH_PROBE_TIMEOUT:-}" ]]; then
    export LNG_HEALTH_PROBE_TIMEOUT="$NAT_FLEET_HEALTH_PROBE_TIMEOUT"
fi

log INFO "Starting client-agent (roster: $NATCTL_ROSTER_URL, interface: $LNG_PRIVATE_IFACE)..."
exec /usr/local/bin/client-agent
