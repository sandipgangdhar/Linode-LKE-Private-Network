#!/bin/bash
# manifests/check-infra-pool-safe-to-delete.sh
#
# Standalone safety check for the manual, deliberate final step of
# post-migration-consolidate.sh: confirms infra-pool has zero non-DaemonSet
# workloads left on it, then - only if that check passes - prints the exact
# cordon/delete commands ready to copy-paste, with the real cluster id and
# pool id filled in.
#
# Deliberately does NOT cordon or delete anything itself. Node pool deletion
# is real, billed, irreversible infrastructure, and post-migration-
# consolidate.sh's own header comment is explicit that this stays a manual
# step on purpose - among other things, infra-pool nodes still existing is
# this repo's entire rollback path if anything about the migration turns
# out to be wrong after the fact (see that script's "Rollback:" section).
# Auto-deleting the moment this check passes would remove that safety net
# right when it might matter most, for the same reason 00-Orchestration-
# script.sh no longer auto-tears-down a deployment on every failure - see
# docs/TROUBLESHOOTING.md entry 19. This script exists so *re-confirming*
# "is it safe yet" - possibly hours or days after migrating, once you've
# actually watched the moved workloads stay healthy for a while - doesn't
# require re-running the whole migration or retyping the pool-delete
# command from memory.
#
# Usage: from repo root: ./manifests/check-infra-pool-safe-to-delete.sh
#        or from manifests/: ./check-infra-pool-safe-to-delete.sh
#
# Exit status: 0 if infra-pool has no non-DaemonSet pods left on it
# (regardless of whether the cluster/pool id could be resolved to print
# ready-to-copy commands), non-zero if anything is still there.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Checking whether infra-pool is safe to delete ==="
echo ""

INFRA_NODES=$(kubectl get nodes -l infra-pool=true -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

if [[ -z "$INFRA_NODES" ]]; then
  echo "No infra-pool nodes found (label infra-pool=true matched nothing) - either"
  echo "already deleted, or this cluster never had one. Nothing to check."
  exit 0
fi

echo "infra-pool nodes: $INFRA_NODES"
echo ""

REMAINING=""
for NODE in $INFRA_NODES; do
  # NOTE: must check "zero DaemonSet-kind owners", not "any non-DaemonSet
  # owner" - the latter is vacuously false for a bare/standalone pod with no
  # ownerReferences at all (e.g. a debug pod left behind from `kubectl run`
  # while troubleshooting on an infra-pool node - confirmed live to
  # reproduce this exact gap), silently treating it the same as an actual
  # DaemonSet pod. See the matching comment in post-migration-consolidate.sh
  # Step 7, which had the identical bug.
  PODS=$(kubectl get pods -A --field-selector spec.nodeName="$NODE" -o json 2>/dev/null | \
    jq -r '.items[] | select([.metadata.ownerReferences[]? | select(.kind == "DaemonSet")] | length == 0) | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || true)
  [[ -n "$PODS" ]] && REMAINING="$REMAINING"$'\n'"  $NODE: $PODS"
done

if [[ -n "$REMAINING" ]]; then
  echo "NOT safe to delete yet - non-DaemonSet pod(s) still on infra-pool node(s):"
  echo "$REMAINING"
  echo ""
  echo "Run post-migration-consolidate.sh first (it's idempotent - safe to re-run),"
  echo "or investigate the pod(s) listed above directly:"
  echo "  kubectl get pod <namespace>/<name> -o wide"
  exit 1
fi

echo "No non-DaemonSet pods on any infra-pool node. Safe to delete, as far as this"
echo "cluster's current workload placement is concerned - use your own judgment on"
echo "whether the migrated workloads (etcd in particular) have been stable for long"
echo "enough that you're comfortable removing the rollback path (see header comment)."
echo ""

# --- Resolve the real cluster id + infra-pool pool id so the commands
#     printed below are ready to copy-paste, not templates to fill in by
#     hand. Best-effort: if either can't be resolved, fall back to generic
#     commands rather than failing outright - the safety check above is the
#     part that actually matters and has already passed by this point.
LKE_CLUSTER_ID="$(kubectl get configmap vlan-manager-config -n kube-system -o jsonpath='{.data.LKE_CLUSTER_ID}' 2>/dev/null || true)"

if [[ -z "$LKE_CLUSTER_ID" ]]; then
  echo "Could not read LKE_CLUSTER_ID from the vlan-manager-config ConfigMap - printing"
  echo "generic commands instead. Fill in <cluster-id>/<pool-id> yourself:"
  echo ""
  echo "  kubectl cordon -l infra-pool=true"
  echo "  linode-cli lke pool-delete <cluster-id> <pool-id>"
  exit 0
fi

if ! command -v linode-cli >/dev/null 2>&1; then
  echo "linode-cli not found on PATH - can't resolve the infra-pool pool id automatically."
  echo "Cluster id is $LKE_CLUSTER_ID. Find the pool id yourself:"
  echo "  linode-cli lke pools-list $LKE_CLUSTER_ID --json | jq '.[] | select(.labels[\"infra-pool\"]==\"true\") | {id, count, type}'"
  echo ""
  echo "Then:"
  echo "  kubectl cordon -l infra-pool=true"
  echo "  linode-cli lke pool-delete $LKE_CLUSTER_ID <pool-id>"
  exit 0
fi

INFRA_POOL_ID="$(linode-cli lke pools-list "$LKE_CLUSTER_ID" --json 2>/dev/null | \
  jq -r '.[] | select(.labels["infra-pool"] == "true") | .id' | head -n1)"

if [[ -z "$INFRA_POOL_ID" ]]; then
  echo "Could not find a pool labeled infra-pool=true on cluster $LKE_CLUSTER_ID via the"
  echo "Linode API (it may already be deleted, or was never labeled at the pool level -"
  echo "see docs/DEPLOYMENT.md Installation step 1). Find the pool id yourself:"
  echo "  linode-cli lke pools-list $LKE_CLUSTER_ID --json | jq '.[] | {id, count, type, labels}'"
  exit 0
fi

echo "Cluster id: $LKE_CLUSTER_ID"
echo "infra-pool id: $INFRA_POOL_ID"
echo ""
echo "Ready to copy-paste when you decide to proceed (neither is run by this script):"
echo ""
echo "  # 1) Cordon as a final safety buffer (stops anything new landing there"
echo "  #    between now and the delete, e.g. if something scales up):"
echo "  kubectl cordon -l infra-pool=true"
echo ""
echo "  # 2) Delete the pool - real, billed instances, irreversible:"
echo "  linode-cli lke pool-delete $LKE_CLUSTER_ID $INFRA_POOL_ID"
