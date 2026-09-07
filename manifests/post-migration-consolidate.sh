#!/bin/bash
# manifests/post-migration-consolidate.sh
#
# Run this ONCE, manually, after the cluster has been up long enough that
# every app-pool (non-infra-pool) node has completed its own VLAN attach
# cycle - i.e. every one of them already carries the label vlan-ready=true,
# set by 02-script-vlan-attach.sh's mark_node_vlan_ready() once VLAN, routes,
# and firewall are confirmed done on that node.
#
# What this does:
#   0. Verifies every non-infra-pool node is vlan-ready=true. Hard abort if
#      not - this is the guard against the Day-0 bootstrap deadlock: etcd
#      and vlan-config-controller must never be repointed at vlan-ready=true
#      while zero/insufficient nodes actually carry that label yet, or they
#      have nowhere required to schedule.
#   1. Re-applies etcd from post-migration/08-etcd-StatefulSet-3node.yaml -
#      same workload/PDB, but scheduling switched from the infra-pool
#      nodeSelector/toleration to a REQUIRED nodeAffinity on vlan-ready=true.
#      This is a normal StatefulSet rolling update onto app-pool nodes.
#   2. Same for vlan-config-controller
#      (post-migration/10-vlan-config-controller.yaml).
#   3. Same for vlan-ip-controller (post-migration/06-vlan-ip-controller-
#      deployment.yaml) - pinned to infra-pool pre-migration since a
#      live-confirmed bug (see docs/TROUBLESHOOTING.md): with it on
#      app-pool, multiple/all app-pool nodes going through their own VLAN/
#      VPC attach cycle at once left it with zero eligible nodes, causing a
#      ReplicaSet pod-creation storm.
#   4. Re-patches CoreDNS the same way (name auto-detected: coredns vs
#      workload-coredns).
#   5. Re-patches Kyverno's 4 Deployments the same way (namespace "kyverno",
#      not kube-system - install_kyverno() in 00-Orchestration-script.sh
#      pins these to infra-pool the same way CoreDNS is pinned, since
#      Kyverno's upstream manifest ships with no tolerations of its own).
#   6. Re-patches the other LKE-managed kube-system workloads
#      auto_pin_lke_system_components() (00-Orchestration-script.sh) pins to
#      infra-pool for the same reason as Kyverno above: cilium-operator,
#      calico-kube-controllers, calico-typha-autoscaler, coredns-autoscaler,
#      konnectivity-agent, konnectivity-autoscaler, and the
#      csi-linode-controller StatefulSet. Skipping this step doesn't just
#      leave a Deployment behind like skipping Kyverno would - it leaves it
#      permanently orphaned once infra-pool is actually deleted (confirmed
#      live - see the comment above that function).
#   7. Confirms nothing non-DaemonSet is left running on infra-pool nodes.
#   8. Prints (but does NOT run) the commands to cordon and delete the
#      infra-pool node pool - deleting a node pool is left as a deliberate,
#      manual step.
#
# Every workload this script moves gets an explicit vlan-not-ready
# toleration as part of the move (app-pool's permanent taint - see
# manifests/09-kyverno-vlan-ready-policy.yaml). All of them are kube-system
# or kyverno namespace workloads, deliberately excluded from Kyverno's own
# linode-lke-vlan-gating policy, so nothing auto-injects this for them.
#
# Rollback: if anything looks wrong partway through, infra-pool nodes are
# never touched/deleted by this script. Roll back by re-applying the
# original manifests and re-patching CoreDNS/Kyverno back to infra-pool:
#   kubectl apply -f 08-etcd-StatefulSet-3node.yaml
#   envsubst '${ETCD_ENDPOINTS}' < 10-vlan-config-controller.yaml | kubectl apply -f -
#   (CoreDNS: re-run the infra-pool patch from docs/DEPLOYMENT.md step 2)
#   (Kyverno: re-run install_kyverno()'s infra-pool patch - see
#    00-Orchestration-script.sh, or manually kubectl patch each of the 4
#    Deployments back to nodeSelector infra-pool=true + that toleration)
#   (Other LKE-managed workloads: re-run auto_pin_lke_system_components()
#    from 00-Orchestration-script.sh, or manually patch each one - see
#    that function for the exact list.)
#
# Usage: from repo root: ./manifests/post-migration-consolidate.sh
#        or from manifests/: ./post-migration-consolidate.sh
#
# Optional: export ETCD_ENDPOINTS before running if you need a custom value.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export ETCD_ENDPOINTS="${ETCD_ENDPOINTS:-http://etcd-0.etcd.kube-system.svc.cluster.local:2379,http://etcd-1.etcd.kube-system.svc.cluster.local:2379,http://etcd-2.etcd.kube-system.svc.cluster.local:2379}"

echo "=== Post-migration consolidation: move etcd, vlan-config-controller, and CoreDNS off infra-pool ==="
echo "Using ETCD_ENDPOINTS=$ETCD_ENDPOINTS"
echo ""

INFRA_NODES=$(kubectl get nodes -l infra-pool=true -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
is_infra_node() {
  local node="$1"
  local n
  for n in $INFRA_NODES; do
    [[ "$n" == "$node" ]] && return 0
  done
  return 1
}

# Deployments (unlike the etcd StatefulSet, which deletes-then-recreates the
# SAME pod name per ordinal) roll out by creating new pods under a NEW
# ReplicaSet while the old pod is still Terminating - `kubectl rollout
# status` reports success once the new pods are Ready, even if an old pod
# on the infra-pool node hasn't finished its terminationGracePeriodSeconds
# yet. Checking node placement immediately after can catch that pod mid-exit
# and report a false failure. This waits/retries and ignores any pod that
# already has a deletionTimestamp set (i.e. is already on its way out).
wait_for_off_infra_pool() {
  local SELECTOR="$1"
  local RETRIES="${2:-12}"
  local SLEEP_SECS="${3:-5}"
  # Defaults to kube-system for backward compatibility with existing call
  # sites (etcd, vlan-config-controller, CoreDNS); Kyverno lives in its own
  # "kyverno" namespace, so this needs to be overridable.
  local NAMESPACE="${4:-kube-system}"
  local STILL=""
  local NODE DELETION i

  for ((i = 1; i <= RETRIES; i++)); do
    STILL=""
    while IFS=$'\t' read -r NODE DELETION; do
      [[ -z "$NODE" ]] && continue
      [[ -n "$DELETION" && "$DELETION" != "<none>" ]] && continue
      if is_infra_node "$NODE"; then
        STILL="$STILL $NODE"
      fi
    done < <(kubectl get pods -n "$NAMESPACE" -l "$SELECTOR" \
        -o jsonpath='{range .items[*]}{.spec.nodeName}{"\t"}{.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null)

    if [[ -z "$STILL" ]]; then
      return 0
    fi
    echo "  [$i/$RETRIES] Old pod(s) still terminating on infra-pool node(s):$STILL - waiting..." >&2
    sleep "$SLEEP_SECS"
  done

  echo "$STILL"
  return 1
}

# ---------------------------------------------------------------------------
# Step 0: Safety check - every app-pool node must already be vlan-ready=true.
# ---------------------------------------------------------------------------
echo "Step 0: Checking that every app-pool node is vlan-ready=true..."
APP_NODES=$(kubectl get nodes -o json | jq -r '.items[] | select(.metadata.labels["infra-pool"] != "true") | .metadata.name')

if [[ -z "$APP_NODES" ]]; then
  echo "  No non-infra-pool nodes found - nothing to consolidate onto. Aborting."
  exit 1
fi

NOT_READY=""
READY_COUNT=0
for NODE in $APP_NODES; do
  READY=$(kubectl get node "$NODE" -o jsonpath='{.metadata.labels.vlan-ready}' 2>/dev/null || true)
  if [[ "$READY" == "true" ]]; then
    READY_COUNT=$((READY_COUNT + 1))
  else
    NOT_READY="$NOT_READY $NODE"
  fi
done

if [[ -n "$NOT_READY" ]]; then
  echo "  The following app-pool node(s) are NOT vlan-ready=true yet:$NOT_READY"
  echo "  Aborting - repointing etcd/vlan-config-controller at vlan-ready=true now"
  echo "  would leave them with nowhere required to schedule until these nodes"
  echo "  finish VLAN attach. Check: kubectl get pods -n kube-system -l app=vlan-manager -o wide"
  exit 1
fi

if [[ "$READY_COUNT" -lt 3 ]]; then
  echo "   Only $READY_COUNT vlan-ready app-pool node(s) found. etcd needs 3 distinct"
  echo "  nodes (pod anti-affinity) and vlan-config-controller needs 2. Continuing is"
  echo "  possible but the rollout may stall waiting for a schedulable node - consider"
  echo "  scaling the app pool up first."
  read -r -p "  Continue anyway? [y/N] " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "  Aborted by user."; exit 1; }
fi

echo "  All $READY_COUNT app-pool node(s) are vlan-ready=true."
echo ""

# ---------------------------------------------------------------------------
# Step 1: etcd
# ---------------------------------------------------------------------------
echo "Step 1: Re-applying etcd with required nodeAffinity on vlan-ready=true..."
kubectl apply -f post-migration/08-etcd-StatefulSet-3node.yaml
echo "  Waiting for etcd StatefulSet rollout..."
kubectl rollout status statefulset/etcd -n kube-system --timeout=600s
echo ""

echo "  Verifying etcd pods are no longer on infra-pool nodes..."
for i in 0 1 2; do
  NODE=$(kubectl get pod etcd-$i -n kube-system -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
  if [[ -z "$NODE" ]]; then
    echo "  etcd-$i has no assigned node (still Pending?). Check: kubectl describe pod etcd-$i -n kube-system"
    exit 1
  fi
  if is_infra_node "$NODE"; then
    echo "  etcd-$i is still on infra-pool node $NODE. Aborting before touching the controller."
    exit 1
  fi
  echo "  etcd-$i -> $NODE"
done
echo ""

# ---------------------------------------------------------------------------
# Step 2: vlan-config-controller
# ---------------------------------------------------------------------------
echo "Step 2: Re-applying vlan-config-controller with required nodeAffinity on vlan-ready=true..."
envsubst '${ETCD_ENDPOINTS}' < post-migration/10-vlan-config-controller.yaml | kubectl apply -f -
echo "  Waiting for vlan-config-controller rollout..."
kubectl rollout status deployment/vlan-config-controller -n kube-system --timeout=300s
echo ""

echo "  Verifying vlan-config-controller pods are no longer on infra-pool nodes..."
if ! STUCK=$(wait_for_off_infra_pool "app=vlan-config-controller"); then
  echo "  vlan-config-controller pod(s) still on infra-pool node(s) after waiting:$STUCK"
  echo "  Check: kubectl get pods -n kube-system -l app=vlan-config-controller -o wide"
  exit 1
fi
CONTROLLER_NODES=$(kubectl get pods -n kube-system -l app=vlan-config-controller --field-selector=status.phase=Running -o jsonpath='{.items[*].spec.nodeName}')
echo "  vlan-config-controller pods: $CONTROLLER_NODES"
echo ""

# ---------------------------------------------------------------------------
# Step 3: vlan-ip-controller
# ---------------------------------------------------------------------------
echo "Step 3: Re-applying vlan-ip-controller with required nodeAffinity on vlan-ready=true..."
envsubst '${ETCD_ENDPOINTS}' < post-migration/06-vlan-ip-controller-deployment.yaml | kubectl apply -f -
echo "  Waiting for vlan-ip-controller rollout..."
kubectl rollout status deployment/vlan-ip-controller -n kube-system --timeout=300s
echo ""

echo "  Verifying vlan-ip-controller pods are no longer on infra-pool nodes..."
if ! STUCK=$(wait_for_off_infra_pool "app=vlan-ip-controller"); then
  echo "  vlan-ip-controller pod(s) still on infra-pool node(s) after waiting:$STUCK"
  echo "  Check: kubectl get pods -n kube-system -l app=vlan-ip-controller -o wide"
  exit 1
fi
IP_CONTROLLER_NODES=$(kubectl get pods -n kube-system -l app=vlan-ip-controller --field-selector=status.phase=Running -o jsonpath='{.items[*].spec.nodeName}')
echo "  vlan-ip-controller pods: $IP_CONTROLLER_NODES"
echo ""

# ---------------------------------------------------------------------------
# Step 4: CoreDNS
# ---------------------------------------------------------------------------
echo "Step 4: Re-patching CoreDNS off infra-pool..."
COREDNS_NAME=$(kubectl get deployments -n kube-system -o name 2>/dev/null | grep -iE 'coredns' | grep -v autoscaler | head -1 | cut -d/ -f2 || true)
# Patch payload includes an explicit infra-pool NotIn clause alongside
# vlan-ready In - same defense-in-depth reasoning as the etcd/controller
# manifests (see comments there): vlan-ready=true alone isn't guaranteed to
# be mutually exclusive with infra-pool=true unless we say so explicitly.
#
# tolerations is set to the vlan-not-ready toleration, NOT null/cleared -
# app-pool nodes carry that taint permanently, so CoreDNS needs an explicit
# toleration for it to land there at all, the same as etcd/vlan-config-
# controller above. It's a kube-system workload, deliberately excluded from
# Kyverno's linode-lke-vlan-gating policy, so nothing auto-injects this.
COREDNS_PATCH='{"spec":{"template":{"spec":{"nodeSelector":{"infra-pool":null},"tolerations":[{"key":"vlan-not-ready","operator":"Equal","value":"true","effect":"NoSchedule"}],"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"vlan-ready","operator":"In","values":["true"]},{"key":"infra-pool","operator":"NotIn","values":["true"]}]}]}}}}}}}'

if [[ -z "$COREDNS_NAME" ]]; then
  echo "   Could not auto-detect the CoreDNS Deployment name. Patch it manually:"
  echo "    kubectl patch deployment <name> -n kube-system --type merge -p '$COREDNS_PATCH'"
else
  echo "  Found CoreDNS Deployment: $COREDNS_NAME"

  # Don't assume the label selector (k8s-app=kube-dns is the classic
  # upstream convention, but LKE Enterprise's workload-coredns doesn't
  # necessarily use it) - read it straight from the Deployment object so
  # this works regardless of which labels this LKE flavor actually uses.
  COREDNS_SELECTOR=$(kubectl get deployment "$COREDNS_NAME" -n kube-system -o json | \
    jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')
  echo "  Using pod selector for $COREDNS_NAME: $COREDNS_SELECTOR"

  kubectl patch deployment "$COREDNS_NAME" -n kube-system --type merge -p "$COREDNS_PATCH"
  kubectl rollout status deployment/"$COREDNS_NAME" -n kube-system --timeout=180s

  if ! STUCK=$(wait_for_off_infra_pool "$COREDNS_SELECTOR"); then
    echo "  CoreDNS pod(s) still on infra-pool node(s) after waiting:$STUCK"
    echo "  Check: kubectl get pods -n kube-system -l '$COREDNS_SELECTOR' -o wide"
    exit 1
  fi
  COREDNS_NODES=$(kubectl get pods -n kube-system -l "$COREDNS_SELECTOR" --field-selector=status.phase=Running -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null || true)
  echo "  CoreDNS pods: $COREDNS_NODES"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 5: Kyverno
# ---------------------------------------------------------------------------
# install_kyverno() (manifests/00-Orchestration-script.sh) pins Kyverno's 4
# Deployments to infra-pool via nodeSelector+toleration, because Kyverno's
# upstream install manifest ships with neither and would otherwise have no
# schedulable node once both pools carry custom taints. Re-patch each one
# here the same way CoreDNS was just re-patched above: drop the infra-pool
# nodeSelector, add the required vlan-ready nodeAffinity (with the same
# infra-pool NotIn defense-in-depth clause), and swap the infra-pool
# toleration for vlan-not-ready. Note Kyverno's namespace is "kyverno", not
# kube-system - the wait_for_off_infra_pool helper takes a namespace so this
# still works.
echo "Step 5: Re-patching Kyverno off infra-pool..."
KYVERNO_PATCH='{"spec":{"template":{"spec":{"nodeSelector":{"infra-pool":null},"tolerations":[{"key":"vlan-not-ready","operator":"Equal","value":"true","effect":"NoSchedule"}],"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"vlan-ready","operator":"In","values":["true"]},{"key":"infra-pool","operator":"NotIn","values":["true"]}]}]}}}}}}}'

if ! kubectl get ns kyverno &>/dev/null; then
  echo "   No 'kyverno' namespace found - Kyverno isn't installed (ENABLE_KYVERNO=false?). Skipping."
else
  for KYVERNO_DEPLOY in kyverno-admission-controller kyverno-background-controller kyverno-cleanup-controller kyverno-reports-controller; do
    if ! kubectl get deployment "$KYVERNO_DEPLOY" -n kyverno &>/dev/null; then
      echo "   $KYVERNO_DEPLOY not found - skipping (may not exist on this Kyverno version)."
      continue
    fi
    echo "  Patching $KYVERNO_DEPLOY..."
    kubectl patch deployment "$KYVERNO_DEPLOY" -n kyverno --type merge -p "$KYVERNO_PATCH"
    kubectl rollout status deployment/"$KYVERNO_DEPLOY" -n kyverno --timeout=180s

    KYVERNO_SELECTOR=$(kubectl get deployment "$KYVERNO_DEPLOY" -n kyverno -o json | \
      jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')
    if ! STUCK=$(wait_for_off_infra_pool "$KYVERNO_SELECTOR" 12 5 kyverno); then
      echo "  $KYVERNO_DEPLOY pod(s) still on infra-pool node(s) after waiting:$STUCK"
      echo "  Check: kubectl get pods -n kyverno -l '$KYVERNO_SELECTOR' -o wide"
      exit 1
    fi
    KYVERNO_NODES=$(kubectl get pods -n kyverno -l "$KYVERNO_SELECTOR" --field-selector=status.phase=Running -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null || true)
    echo "  $KYVERNO_DEPLOY pods: $KYVERNO_NODES"
  done
fi
echo ""

# ---------------------------------------------------------------------------
# Step 6: Other LKE-managed kube-system workloads pinned to infra-pool by
# auto_pin_lke_system_components() (manifests/00-Orchestration-script.sh) -
# cilium-operator, calico-kube-controllers, calico-typha-autoscaler,
# coredns-autoscaler, konnectivity-agent, konnectivity-autoscaler, and the
# csi-linode-controller StatefulSet. Like Kyverno above, these ship with no
# tolerations of their own and have nowhere to schedule once both pools
# carry custom taints - unlike Kyverno, missing this step doesn't just
# leave a Deployment behind, it leaves it ORPHANED (stuck Pending forever)
# the moment infra-pool is actually deleted, since cilium-operator in
# particular has no DaemonSet-style fallback. Confirmed live: running this
# migration without this step left exactly these workloads behind on
# infra-pool, flagged as unexpected by the check that's now Step 7 below.
# ---------------------------------------------------------------------------
echo "Step 6: Re-patching other LKE-managed system workloads off infra-pool..."
LKE_SYSTEM_PATCH='{"spec":{"template":{"spec":{"nodeSelector":{"infra-pool":null},"tolerations":[{"key":"vlan-not-ready","operator":"Equal","value":"true","effect":"NoSchedule"}],"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"vlan-ready","operator":"In","values":["true"]},{"key":"infra-pool","operator":"NotIn","values":["true"]}]}]}}}}}}}'

# konnectivity-autoscaler AND konnectivity-agent-autoscaler are both listed
# deliberately, not a typo - confirmed live, the Deployment name differs by
# cluster type ("konnectivity-autoscaler" on Enterprise, "konnectivity-
# agent-autoscaler" on Standard). See the matching comment in
# 00-Orchestration-script.sh's LKE_SYSTEM_DEPLOYMENTS_NEEDING_PIN.
for LKE_SYSTEM_DEPLOY in cilium-operator calico-kube-controllers calico-typha-autoscaler coredns-autoscaler konnectivity-agent konnectivity-autoscaler konnectivity-agent-autoscaler; do
  if ! kubectl get deployment "$LKE_SYSTEM_DEPLOY" -n kube-system &>/dev/null; then
    continue
  fi
  echo "  Patching $LKE_SYSTEM_DEPLOY..."
  kubectl patch deployment "$LKE_SYSTEM_DEPLOY" -n kube-system --type merge -p "$LKE_SYSTEM_PATCH"
  kubectl rollout status deployment/"$LKE_SYSTEM_DEPLOY" -n kube-system --timeout=180s

  LKE_SYSTEM_SELECTOR=$(kubectl get deployment "$LKE_SYSTEM_DEPLOY" -n kube-system -o json | \
    jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')
  if ! STUCK=$(wait_for_off_infra_pool "$LKE_SYSTEM_SELECTOR"); then
    echo "  $LKE_SYSTEM_DEPLOY pod(s) still on infra-pool node(s) after waiting:$STUCK"
    echo "  Check: kubectl get pods -n kube-system -l '$LKE_SYSTEM_SELECTOR' -o wide"
    exit 1
  fi
  echo "  $LKE_SYSTEM_DEPLOY moved off infra-pool."
done

if kubectl get statefulset csi-linode-controller -n kube-system &>/dev/null; then
  echo "  Patching csi-linode-controller..."
  kubectl patch statefulset csi-linode-controller -n kube-system --type merge -p "$LKE_SYSTEM_PATCH"
  # StatefulSets don't recreate an already-Pending/existing pod on template
  # change by themselves (see the same note in auto_pin_lke_system_components())
  kubectl delete pod -n kube-system -l app=csi-linode-controller --ignore-not-found >/dev/null 2>&1 || true
  kubectl rollout status statefulset/csi-linode-controller -n kube-system --timeout=180s
  if ! STUCK=$(wait_for_off_infra_pool "app=csi-linode-controller"); then
    echo "  csi-linode-controller pod(s) still on infra-pool node(s) after waiting:$STUCK"
    echo "  Check: kubectl get pods -n kube-system -l app=csi-linode-controller -o wide"
    exit 1
  fi
  echo "  csi-linode-controller moved off infra-pool."
fi
echo ""

# ---------------------------------------------------------------------------
# Step 7: Final check - anything non-DaemonSet still on infra-pool nodes?
# ---------------------------------------------------------------------------
echo "Step 7: Checking for any remaining workloads on infra-pool nodes..."
REMAINING=""
for NODE in $INFRA_NODES; do
  # NOTE: this must NOT be `any(.metadata.ownerReferences[]?; .kind !=
  # "DaemonSet")` - that reads as "flag anything with at least one non-
  # DaemonSet owner", but `any` over an EMPTY array is vacuously false, so a
  # bare/standalone pod (no ownerReferences at all - e.g. a debug pod
  # someone manually `kubectl run` on an infra-pool node while
  # troubleshooting, confirmed live to reproduce this exact gap) matched
  # nothing and was silently treated as safe to ignore, same as an actual
  # DaemonSet pod. The correct check is "does this pod have zero
  # DaemonSet-kind owners", which correctly flags both a bare pod and a
  # Deployment/StatefulSet/Job-owned one, and correctly skips only pods that
  # genuinely have a DaemonSet owner.
  PODS=$(kubectl get pods -A --field-selector spec.nodeName="$NODE" -o json 2>/dev/null | \
    jq -r '.items[] | select([.metadata.ownerReferences[]? | select(.kind == "DaemonSet")] | length == 0) | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || true)
  [[ -n "$PODS" ]] && REMAINING="$REMAINING"$'\n'"  $NODE: $PODS"
done

if [[ -n "$REMAINING" ]]; then
  echo "   Non-DaemonSet pods still on infra-pool nodes:"
  echo "$REMAINING"
  echo "  Investigate before deleting the pool."
else
  echo "  No remaining non-DaemonSet pods on infra-pool nodes. Safe to delete the pool."
fi
echo ""

echo "=== Consolidation complete. ==="
echo ""
echo "Next (manual, not run by this script):"
echo "  Whenever you're ready (could be right now, could be days from now once"
echo "  you're comfortable removing the rollback path below), re-confirm and get"
echo "  the exact cordon/delete commands with real ids filled in:"
echo "     ./check-infra-pool-safe-to-delete.sh"
echo ""
echo "If you need to roll back before deleting the pool, infra-pool nodes were"
echo "never touched by this script - just re-apply the original manifests:"
echo "  kubectl apply -f 08-etcd-StatefulSet-3node.yaml"
echo "  envsubst '\${ETCD_ENDPOINTS}' < 10-vlan-config-controller.yaml | kubectl apply -f -"
echo "  (CoreDNS: re-patch back to infra-pool per docs/DEPLOYMENT.md step 2)"
echo "  (Kyverno: re-run install_kyverno()'s infra-pool patch, see 00-Orchestration-script.sh)"
echo ""
