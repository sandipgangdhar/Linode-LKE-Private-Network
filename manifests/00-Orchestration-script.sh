#!/bin/bash

set -o pipefail

# === Orchestration Script ===
# This script automates the deployment of VLAN Manager and associated services in Kubernetes.

DEPLOYMENT_SUCCESS="false"

# === Detect fresh deploy vs. re-run, before this script does anything ===
#
# Found live, the hard way: this script used to auto-cleanup (tear down
# EVERYTHING it manages - etcd, its PVCs, both controllers, Kyverno's
# policy, every ConfigMap/Secret) on ANY failure anywhere in the script,
# unconditionally. That's a reasonable safety net for a genuinely fresh
# deploy that never worked in the first place - nothing of value existed
# yet, so tearing down a half-finished attempt to retry cleanly is fine.
# It is NOT reasonable for a routine re-run against a cluster that
# already has a fully working deployment: a single transient failure
# anywhere (a flaky health check, a slow API server, anything) used to
# delete a healthy, already-working etcd cluster - including its PVCs -
# along with everything else, as a side effect of that one unrelated
# blip. Confirmed live: exactly this happened from a health-check false
# negative caused by a rolling-update timing race (see the LEADER_POD fix
# further down) - a completely healthy deployment was destroyed by a
# problem that had nothing to do with any of the resources actually
# deleted.
#
# is_fresh_deploy() checks whether any of the core resources this script
# manages already exist. If even one does, this is a re-run against an
# existing deployment, not a first-time deploy - cleanup() below will
# skip its destructive steps entirely in that case, no matter what fails
# later in this run. Checked once, up front, before this script changes
# anything - deliberately not re-checked later, so a mid-run failure
# can't second-guess what was true at the start.
is_fresh_deploy() {
  ! kubectl get statefulset etcd -n kube-system >/dev/null 2>&1 &&
  ! kubectl get deployment vlan-config-controller -n kube-system >/dev/null 2>&1 &&
  ! kubectl get deployment vlan-ip-controller -n kube-system >/dev/null 2>&1 &&
  ! kubectl get daemonset vlan-manager -n kube-system >/dev/null 2>&1
}

if is_fresh_deploy; then
  IS_FRESH_DEPLOY="true"
else
  IS_FRESH_DEPLOY="false"
  echo "Existing vlan-manager resources found - this is a re-run against an already-deployed cluster, not a first-time deploy. If this run fails, it will report the error and stop WITHOUT tearing anything down (see is_fresh_deploy() above for why)."
fi

# === Cleanup Function ===
# Does the actual, unconditional teardown - called two different ways
# below, deliberately gated differently:
#   - Directly, for the explicit `--cleanup` flag: the user asked for a
#     full teardown by name, so it always runs, regardless of whether
#     anything currently looks like a "fresh" or "existing" deploy.
#   - Via cleanup_on_unexpected_failure() (the EXIT trap), which adds the
#     IS_FRESH_DEPLOY gate - see that function's comment for why.
# Keeping this function itself gate-free is what keeps `--cleanup`
# working correctly; putting the gate here instead would silently break
# `--cleanup` on any cluster that already has resources on it, which is
# precisely the situation `--cleanup` exists to handle.
cleanup() {
    echo "Deployment failed. Performing cleanup..."

    echo "Cleaning up VLAN IP Reconciler CronJob..."
    kubectl delete cronjob vlan-ip-reconciler -n kube-system --ignore-not-found && echo "VLAN IP Reconciler CronJob deleted."

    echo "Cleaning up Kyverno policy (VLAN-ready gate)..."
    # Delete both policy types unconditionally - only one is ever actually
    # applied at a time (see apply_kyverno_policy()'s dispatch logic), but
    # --ignore-not-found makes deleting the absent one a harmless no-op, and
    # this way cleanup works correctly regardless of which type this
    # cluster's Kyverno version put in place.
    kubectl delete clusterpolicy linode-lke-vlan-gating --ignore-not-found && echo "Kyverno ClusterPolicy deleted."
    kubectl delete mutatingpolicy linode-lke-vlan-gating --ignore-not-found && echo "Kyverno MutatingPolicy deleted."

    echo "Cleaning up Initializer Job..."
    kubectl delete job vlan-ip-initializer -n kube-system --ignore-not-found && echo "Initializer Job deleted."
    
    echo "Cleaning up VLAN Manager DaemonSet..."
    kubectl delete daemonset vlan-manager -n kube-system --ignore-not-found && echo "VLAN Manager DaemonSet deleted."

    echo "Cleaning up vlan-config-controller Deployment... "
    kubectl delete deployment vlan-config-controller -n kube-system --ignore-not-found && echo "VLAN vlan-config-controller Deployment deleted."
    
    echo "Cleaning up ConfigMaps..."
    kubectl delete configmap vlan-manager-scripts -n kube-system --ignore-not-found && echo "vlan-manager-scripts ConfigMap deleted."
    kubectl delete configmap linode-cli-config -n kube-system --ignore-not-found && echo "linode-cli-config ConfigMap deleted."
    kubectl delete configmap vlan-manager-config -n kube-system --ignore-not-found && echo "vlan-manager-config ConfigMap deleted."

    echo "Cleaning up Secret..."
    kubectl delete secret vlan-manager-secrets -n kube-system --ignore-not-found && echo "vlan-manager-secrets Secret deleted."
    
    echo "Cleaning up etcd StatefulSet and Services..."
    kubectl delete statefulset etcd -n kube-system --ignore-not-found && echo "etcd StatefulSet deleted."
    kubectl delete service etcd -n kube-system --ignore-not-found && echo "etcd Service deleted."
    kubectl delete service etcd-headless -n kube-system --ignore-not-found && echo "etcd Headless Service deleted."
    kubectl delete pvc -l app=etcd -n kube-system --ignore-not-found && echo "etcd PVCs deleted."

    echo "Cleaning up VLAN IP CONTROLLER Deployment..."
    kubectl delete deployment vlan-ip-controller -n kube-system --ignore-not-found && echo "VLAN Leader Manager Deployment deleted."
    kubectl delete service vlan-ip-controller-service -n kube-system --ignore-not-found && echo "VLAN IP CONTROLLER service deleted."

    echo "Cleanup complete."
}

# === Argument Parsing ===
if [[ "$1" == "--cleanup" ]]; then
    echo "Cleanup flag detected. Initiating cleanup..."
    cleanup
    exit 0
fi

# EXIT-trap entry point - NOT called directly for --cleanup above (see the
# comment on cleanup() for why that matters). Adds two gates on top of the
# raw cleanup():
#   1. DEPLOYMENT_SUCCESS - unchanged from before: a clean successful run
#      never triggers cleanup on exit.
#   2. IS_FRESH_DEPLOY - new: an unexpected failure only auto-tears-down
#      resources that this same run created. If resources already existed
#      before this run started, a failure leaves them alone entirely - see
#      the comment on is_fresh_deploy() near the top of this file for the
#      live-confirmed incident that motivated this.
cleanup_on_unexpected_failure() {
    if [[ "${DEPLOYMENT_SUCCESS}" == "true" ]]; then
      return 0
    fi
    if [[ "${IS_FRESH_DEPLOY}" != "true" ]]; then
      echo "This run failed, but existing resources were already present before it started (not a first-time deploy) - skipping automatic cleanup so a working deployment is never torn down by an unrelated failure. Nothing has been deleted. Investigate the error above; re-run this script once it's fixed, or run with --cleanup if you deliberately want a full teardown."
      return 0
    fi
    cleanup
}

trap cleanup_on_unexpected_failure EXIT

# === Function to log messages ===
log() {
    echo -e "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# === Kyverno install + wait helpers ===
# See manifests/09-kyverno-vlan-ready-policy.yaml for why this exists again
# after being retired earlier - short version: it's now scoped to avoid the
# two bugs that caused its retirement (nodeSelectorTerms merge collisions
# between independent projects' policies, and autogenerated rules mutating
# owning controllers instead of just Pods).

KYVERNO_INSTALL_URL="${KYVERNO_INSTALL_URL:-https://github.com/kyverno/kyverno/releases/latest/download/install.yaml}"
KYVERNO_NAMESPACE="${KYVERNO_NAMESPACE:-kyverno}"
# Legacy kyverno.io/v1 ClusterPolicy - deprecated as of Kyverno v1.19,
# scheduled for removal in v1.20 (~October 2026). Kept only as the
# fallback path for a Kyverno version old enough not to ship the CEL-based
# MutatingPolicy CRD yet - see apply_kyverno_policy() below.
KYVERNO_POLICY_FILE="${KYVERNO_POLICY_FILE:-09-kyverno-vlan-ready-policy.yaml}"
# CEL-based policies.kyverno.io/v1 MutatingPolicy - the supported
# replacement, applied whenever its CRD is available on the target
# cluster. See manifests/09-kyverno-vlan-ready-mutatingpolicy.yaml's
# header for the full rationale.
KYVERNO_MUTATINGPOLICY_FILE="${KYVERNO_MUTATINGPOLICY_FILE:-09-kyverno-vlan-ready-mutatingpolicy.yaml}"

install_kyverno() {
    log "Checking Kyverno installation..."

    # If CRD exists, Kyverno is already installed (or at least CRDs are
    # present) - possibly by a sibling project sharing this cluster (e.g.
    # lke-e-acl-operator, which can legitimately install Kyverno first if
    # deployed before this project). Either way, skip re-running the install
    # manifest - kubectl create (not apply) would fail with AlreadyExists on
    # every object in it - but DO NOT return early: the pinning/toleration
    # patch below must still run unconditionally, see the comment above it
    # for why.
    local kyverno_freshly_installed="false"
    if kubectl get crd clusterpolicies.kyverno.io &>/dev/null; then
        log "Kyverno CRDs already present (possibly installed by another project on this cluster). Skipping install manifest."
    else
        log "Installing Kyverno from: $KYVERNO_INSTALL_URL"
        # --validate=false skips kubectl's client-side OpenAPI schema fetch
        # against the API server before applying (a single large /openapi/v2
        # request, triggered because this is a big multi-CRD remote bundle -
        # every other kubectl call in this script targets small, already-known
        # objects and never hits this path). That fetch has been observed to
        # time out even against an otherwise-healthy cluster; skipping it just
        # means validation happens server-side instead, which still catches
        # malformed manifests. Retry a few times since this is installing from
        # a remote URL and a transient network blip shouldn't be fatal.
        local kyverno_install_attempt
        for kyverno_install_attempt in 1 2 3; do
            if kubectl create -f "$KYVERNO_INSTALL_URL" --validate=false; then
                log "Kyverno install manifest applied."
                break
            fi
            log "Kyverno install manifest apply failed (attempt ${kyverno_install_attempt}/3)."
            if [[ "$kyverno_install_attempt" == 3 ]]; then
                log "Kyverno install failed after 3 attempts."
                return 1
            fi
            sleep 10
        done

        log "Waiting for Kyverno namespace to exist..."
        for i in {1..30}; do
            if kubectl get ns "$KYVERNO_NAMESPACE" &>/dev/null; then
                log "Kyverno namespace found: $KYVERNO_NAMESPACE"
                break
            fi
            sleep 2
        done
        kyverno_freshly_installed="true"
    fi

    # Kyverno's upstream install manifest ships with zero tolerations and no
    # nodeSelector - it expects to be schedulable anywhere. On this project's
    # clusters BOTH node pools carry a custom taint (app-pool's permanent
    # "vlan-not-ready", infra-pool's "infra-pool"), so with no patch Kyverno
    # has no node in the entire cluster it's allowed to land on and its pods
    # sit Pending forever. Pin it onto infra-pool instead, the same place
    # etcd/vlan-config-controller already live - Kyverno is cluster
    # infrastructure, not an application workload, so it belongs there.
    #
    # This MUST run every time this function runs, not just on a fresh
    # install (moved out of the "just installed" branch above on purpose).
    # If a sibling project (e.g. lke-e-acl-operator) is deployed first and
    # installs Kyverno without pinning it anywhere - its own script only
    # warns, it doesn't patch - this project running second would previously
    # hit the CRDs-already-present branch and return before ever reaching
    # this patch, leaving Kyverno's pods with zero tolerations on a cluster
    # where every pool now carries a custom taint. It would look completely
    # healthy at deploy time (existing pods keep running on whatever node
    # they happened to land on originally) and then fail silently the next
    # time any Kyverno pod gets rescheduled - node loss, drain, upgrade,
    # restart - with nowhere left to land. Running this unconditionally
    # closes that gap regardless of which project deploys first.
    #
    # tolerations is a list with no strategic-merge key, so a naive
    # patchStrategicMerge here would fully REPLACE whatever's already on the
    # Deployment - e.g. wiping out an acl-not-ready toleration a sibling
    # project's own manual step already added - the exact class of bug this
    # whole two-project design exists to avoid, just at the Kyverno-pod
    # pinning layer instead of the ClusterPolicy layer. So: nodeSelector
    # (a safe, mergeable map) goes through patchStrategicMerge; tolerations
    # is checked first and only appended via JSON Patch if our entry isn't
    # already there, never blindly replaced.
    # infra_pool_migration_already_done() (defined further down, resolved at
    # call time so the earlier textual position of this function doesn't
    # matter): without this check, this unconditional-by-design re-pin
    # would just as unconditionally UNDO post-migration-consolidate.sh's
    # Step 4 (which moves Kyverno's Deployments onto vlan-ready instead) on
    # the very next orchestration script re-run - confirmed live, the same
    # session that added this guard, for the CoreDNS/other-LKE-system-
    # component version of this exact bug (see infra_pool_migration_already_done()'s
    # own comment and TROUBLESHOOTING.md).
    if infra_pool_migration_already_done; then
        log "This cluster has already been through post-migration-consolidate.sh - skipping Kyverno infra-pool pinning so this run doesn't fight that migration."
    else
        log "Ensuring Kyverno deployments are pinned to infra-pool (see comment above for why this always runs, fresh install or not)..."
        for kyverno_deploy in kyverno-admission-controller kyverno-background-controller kyverno-cleanup-controller kyverno-reports-controller; do
            kubectl patch deployment "$kyverno_deploy" -n "$KYVERNO_NAMESPACE" --type strategic -p '{
              "spec": {"template": {"spec": {"nodeSelector": {"infra-pool": "true"}}}}
            }' 2>/dev/null || log "Could not patch nodeSelector on $kyverno_deploy (may not exist yet on this Kyverno version - continuing)."

            existing_tolerations=$(kubectl get deployment "$kyverno_deploy" -n "$KYVERNO_NAMESPACE" -o jsonpath='{.spec.template.spec.tolerations}' 2>/dev/null || echo "")
            if echo "$existing_tolerations" | grep -q '"key":"infra-pool"'; then
                log "$kyverno_deploy already tolerates the infra-pool taint."
            elif [[ -z "$existing_tolerations" ]]; then
                kubectl patch deployment "$kyverno_deploy" -n "$KYVERNO_NAMESPACE" --type strategic -p '{
                  "spec": {"template": {"spec": {"tolerations": [{"key": "infra-pool", "operator": "Equal", "value": "true", "effect": "NoSchedule"}]}}}
                }' 2>/dev/null || log "Could not patch tolerations on $kyverno_deploy (may not exist yet on this Kyverno version - continuing)."
            else
                kubectl patch deployment "$kyverno_deploy" -n "$KYVERNO_NAMESPACE" --type=json -p='[
                  {"op":"add","path":"/spec/template/spec/tolerations/-","value":{"key":"infra-pool","operator":"Equal","value":"true","effect":"NoSchedule"}}
                ]' 2>/dev/null || log "Could not append toleration on $kyverno_deploy (may not exist yet on this Kyverno version - continuing)."
            fi
        done
    fi

    log "Waiting for Kyverno pods to be Ready..."
    # Wait for deployments if present (Kyverno install creates deployments).
    # Use a soft approach to avoid failing if deployment names change slightly across versions.
    #
    # Run all 5 waits concurrently rather than one after another - they're
    # independent Deployments, and each can legitimately take a couple of
    # minutes (the pin above just triggered a rolling update on 4 of them).
    # Confirmed live: this block took ~10 minutes sequentially on a redeploy
    # where every controller had an old replica pending termination: each
    # `rollout status` waited out that termination back-to-back instead of
    # all four overlapping.
    local -a kyverno_wait_pids=()
    local kyverno_deploy_name kyverno_wait_pid
    for kyverno_deploy_name in kyverno kyverno-admission-controller kyverno-background-controller kyverno-cleanup-controller kyverno-reports-controller; do
        kubectl -n "$KYVERNO_NAMESPACE" rollout status deploy/"$kyverno_deploy_name" --timeout=300s 2>/dev/null &
        kyverno_wait_pids+=("$!")
    done
    for kyverno_wait_pid in "${kyverno_wait_pids[@]}"; do
        wait "$kyverno_wait_pid" || true
    done

    wait_for_kyverno_crds
}

wait_for_kyverno_crds() {
    log "Waiting for Kyverno CRDs to become available..."
    for i in {1..60}; do
        if kubectl get crd clusterpolicies.kyverno.io &>/dev/null && \
           kubectl get crd policies.kyverno.io &>/dev/null; then
            log "Kyverno CRDs are available."
            return 0
        fi
        sleep 2
    done

    log "Kyverno CRDs did not become available in time."
    return 1
}

# Detects whether this cluster's Kyverno ships the CEL-based
# policies.kyverno.io/v1 MutatingPolicy CRD. True on any Kyverno recent
# enough to have it (confirmed live on this project's own clusters running
# v1.19.0); false only on an old enough Kyverno install that the CRD was
# never registered, in which case we fall back to the legacy ClusterPolicy
# so this script still works against an unupgraded cluster.
mutating_policy_crd_available() {
    kubectl get crd mutatingpolicies.policies.kyverno.io &>/dev/null
}

# Dispatcher: picks exactly one policy TYPE for this cluster and applies
# it, deleting whichever type it did NOT pick if a stale copy is present
# from a previous run or an older Kyverno version. Never leaves both types
# active at once - see 09-kyverno-vlan-ready-mutatingpolicy.yaml's header
# for why that matters (duplicate, independently-appended tolerations).
apply_kyverno_policy() {
    wait_for_kyverno_crds

    if mutating_policy_crd_available; then
        log "mutatingpolicies.policies.kyverno.io CRD available - using CEL-based MutatingPolicy."
        kubectl delete clusterpolicy linode-lke-vlan-gating --ignore-not-found
        apply_kyverno_mutatingpolicy
    else
        log "mutatingpolicies.policies.kyverno.io CRD not available on this Kyverno install - falling back to legacy ClusterPolicy. Note: kyverno.io/v1 ClusterPolicy is deprecated as of Kyverno v1.19 and scheduled for removal in v1.20 (~October 2026) - upgrade Kyverno on this cluster before then."
        kubectl delete mutatingpolicy linode-lke-vlan-gating --ignore-not-found
        apply_kyverno_clusterpolicy
    fi
}

apply_kyverno_clusterpolicy() {
    log "Applying Kyverno policy: $KYVERNO_POLICY_FILE"

    if [ ! -f "$KYVERNO_POLICY_FILE" ]; then
        log "Kyverno policy file not found: $KYVERNO_POLICY_FILE"
        exit 1
    fi

    # NOTE: this used to run unchecked - kubectl apply's exit code was
    # ignored and the "applied successfully" log line printed unconditionally
    # right after, regardless of outcome. That let a real failure (e.g. a
    # strict-decoding rejection from an unknown/misplaced field) pass by
    # silently, leaving Kyverno healthy but the ClusterPolicy never actually
    # installed - discovered live when app pods stayed Pending with zero
    # mutation despite Kyverno itself reporting all pods Running. Now we
    # check the exit code and fail loudly instead.
    if ! kubectl apply -f "$KYVERNO_POLICY_FILE"; then
        log "Failed to apply Kyverno policy: $KYVERNO_POLICY_FILE"
        log "Kyverno is running but the VLAN gating policy is NOT installed - app pods will stay Pending."
        exit 1
    fi

    if ! kubectl get clusterpolicy linode-lke-vlan-gating >/dev/null 2>&1; then
        log "kubectl apply reported success but clusterpolicy linode-lke-vlan-gating still not found - aborting."
        exit 1
    fi

    log "Waiting for ClusterPolicy linode-lke-vlan-gating to become ready..."
    for i in {1..60}; do
        if [[ "$(kubectl get clusterpolicy linode-lke-vlan-gating -o jsonpath='{.status.conditions[0].status}' 2>/dev/null)" == "True" ]]; then
            log "Kyverno ClusterPolicy applied successfully and ready."
            kubectl get clusterpolicy linode-lke-vlan-gating
            return 0
        fi
        sleep 2
    done

    log "clusterpolicy linode-lke-vlan-gating did not report ready in time - check kubectl get clusterpolicy linode-lke-vlan-gating -o yaml for details."
    exit 1
}

apply_kyverno_mutatingpolicy() {
    log "Applying Kyverno policy: $KYVERNO_MUTATINGPOLICY_FILE"

    if [ ! -f "$KYVERNO_MUTATINGPOLICY_FILE" ]; then
        log "Kyverno policy file not found: $KYVERNO_MUTATINGPOLICY_FILE"
        exit 1
    fi

    if ! kubectl apply -f "$KYVERNO_MUTATINGPOLICY_FILE"; then
        log "Failed to apply Kyverno policy: $KYVERNO_MUTATINGPOLICY_FILE"
        log "Kyverno is running but the VLAN gating policy is NOT installed - app pods will stay Pending."
        exit 1
    fi

    if ! kubectl get mutatingpolicy linode-lke-vlan-gating >/dev/null 2>&1; then
        log "kubectl apply reported success but mutatingpolicy linode-lke-vlan-gating still not found - aborting."
        exit 1
    fi

    # MutatingPolicy's ready condition lives at a different path than
    # ClusterPolicy's - status.conditionStatus.ready (a boolean), not
    # status.conditions[0].status - confirmed by inspecting both live.
    log "Waiting for MutatingPolicy linode-lke-vlan-gating to become ready..."
    for i in {1..60}; do
        if [[ "$(kubectl get mutatingpolicy linode-lke-vlan-gating -o jsonpath='{.status.conditionStatus.ready}' 2>/dev/null)" == "true" ]]; then
            log "Kyverno MutatingPolicy applied successfully and ready."
            kubectl get mutatingpolicy linode-lke-vlan-gating
            return 0
        fi
        sleep 2
    done

    log "mutatingpolicy linode-lke-vlan-gating did not report ready in time - check kubectl get mutatingpolicy linode-lke-vlan-gating -o yaml for details (likely a CEL compile error)."
    exit 1
}

apply_vlan_config_controller() {

  echo "Deploying VLAN Config Controller..."

  # See the matching guard + comment in deploy_etcd_cluster() above - same
  # reasoning, same live-confirmed bug: without this, re-running this
  # script on an already-migrated cluster would silently move
  # vlan-config-controller back onto infra-pool, undoing post-migration-
  # consolidate.sh's Step 2. Once migrated, this Deployment's manifest is
  # owned by post-migration-consolidate.sh alone.
  if infra_pool_migration_already_done; then
    log "This cluster has already been through post-migration-consolidate.sh (etcd is on vlan-ready, not infra-pool) - skipping vlan-config-controller re-apply so this run doesn't move it back."
    return 0
  fi

  NODE_COUNT=$(get_worker_node_count)
  log "Detected $NODE_COUNT worker node(s) in the cluster."

  if [ "$NODE_COUNT" -lt 3 ]; then
      log "Node count <$NODE_COUNT> is less than 3 setting the etcd endpoint accordingly..."
      export ETCD_ENDPOINTS="http://etcd-0.etcd.kube-system.svc.cluster.local:2379"
      envsubst '${ETCD_ENDPOINTS}' < 10-vlan-config-controller.yaml | kubectl apply -f -
      unset ETCD_ENDPOINTS
  else
      log "Node count is $NODE_COUNT setting the etcd endpoint accordingly..."
      export ETCD_ENDPOINTS="http://etcd-0.etcd.kube-system.svc.cluster.local:2379,http://etcd-1.etcd.kube-system.svc.cluster.local:2379,http://etcd-2.etcd.kube-system.svc.cluster.local:2379"
      envsubst '${ETCD_ENDPOINTS}' < 10-vlan-config-controller.yaml | kubectl apply -f -
      unset ETCD_ENDPOINTS
  fi


  if [[ $? -ne 0 ]]; then
    echo "Failed to deploy VLAN Config Controller"
    exit 1
  fi

  echo "Waiting for Controller rollout..."
  echo "Verifying Controller Pod..."
  kubectl -n kube-system rollout status deployment/vlan-config-controller --timeout=180s

  if [[ $? -ne 0 ]]; then
    echo "Controller failed to become ready"
    exit 1
  fi

  echo "VLAN Config Controller deployed successfully"
}

############################################
# Function: Create & Apply VLAN Scripts ConfigMap
############################################
apply_vlan_manager_scripts_configmap() {
  echo "Generating VLAN Manager Scripts ConfigMap dynamically..."

  NAMESPACE="kube-system"
  CONFIGMAP_NAME="vlan-manager-scripts"

  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  SCRIPTS_DIR="${ROOT_DIR}/scripts"

  # Safety checks
  if [[ ! -d "${SCRIPTS_DIR}" ]]; then
    echo "Scripts directory not found: ${SCRIPTS_DIR}"
    exit 1
  fi

  if ! command -v kubectl >/dev/null 2>&1; then
    echo "kubectl not found in PATH"
    exit 1
  fi

  echo "Using scripts directory: ${SCRIPTS_DIR}"

  # Delete existing ConfigMap (safe & idempotent)
  kubectl -n "${NAMESPACE}" delete cm "${CONFIGMAP_NAME}" \
    --ignore-not-found=true

  # Create ConfigMap dynamically from scripts directory. A direct `create`,
  # not `--dry-run=client -o yaml | kubectl apply -f -` -- the ConfigMap was
  # just unconditionally deleted above, so there's nothing for `apply`'s
  # merge semantics to add here, and `kubectl apply` always writes a
  # kubectl.kubernetes.io/last-applied-configuration annotation containing
  # the ENTIRE object content, base64-encoded, a second time -- annotations
  # are hard-capped at 256KiB by the Kubernetes API server itself
  # (unrelated to, and much stricter than, etcd's own request-size limit).
  # Confirmed live: shc-compiled scripts/*.sh (always larger than their
  # plaintext source, due to the C wrapper + encrypted payload overhead)
  # pushed the base64'd annotation copy over that cap with
  # "metadata.annotations: Too long: may not be more than 262144 bytes",
  # even though the ConfigMap's own actual data was comfortably under the
  # separate (and much larger) etcd request-size ceiling. This repo's own
  # plaintext scripts/*.sh have always stayed just under 256KiB, which is
  # why this dormant bug never surfaced before compiled scripts existed.
  kubectl -n "${NAMESPACE}" create cm "${CONFIGMAP_NAME}" \
    --from-file="${SCRIPTS_DIR}"

  if [[ $? -ne 0 ]]; then
    echo "Failed to create ${CONFIGMAP_NAME}"
    exit 1
  fi

  echo "${CONFIGMAP_NAME} ConfigMap created/updated successfully"
}

# === Function to get Kubernetes node count ===
get_worker_node_count() {
    kubectl get nodes --no-headers | wc -l
}

# === Decide etcd deployment type based on node count ===
deploy_etcd_cluster() {
    # infra_pool_migration_already_done() is defined later in this file,
    # resolved at call time - by the time this function is actually
    # invoked (Step 4, well after the whole script has been parsed), it
    # exists. Without this check, re-running this orchestration script on
    # an already-migrated cluster would re-apply the infra-pool-pinned
    # manifest here and silently move etcd BACK off vlan-ready onto
    # infra-pool, undoing post-migration-consolidate.sh's Step 1 - a much
    # more consequential version of the same bug found (and fixed) for
    # CoreDNS/Kyverno/the other LKE-system components elsewhere in this
    # file. Confirmed this would happen live before this guard existed.
    # Once migrated, etcd's manifest is owned by post-migration-
    # consolidate.sh alone; this function has nothing left to do.
    if infra_pool_migration_already_done; then
        log "This cluster has already been through post-migration-consolidate.sh (etcd is on vlan-ready, not infra-pool) - skipping etcd re-apply so this run doesn't move it back."
        return 0
    fi

    NODE_COUNT=$(get_worker_node_count)
    log "Detected $NODE_COUNT worker node(s) in the cluster."

    if [ "$NODE_COUNT" -lt 3 ]; then
        log "Node count <$NODE_COUNT> is less than 3. Deploying single-node etcd setup (standalone mode)..."
        kubectl apply -f 08-etcd-StatefulSet-1node.yaml
    else
        log "Node count is $NODE_COUNT. Deploying 3-node etcd setup (HA mode)..."
        kubectl apply -f 08-etcd-StatefulSet-3node.yaml
    fi
}

# === setting the etcd endpoint based on node count ===
Apply_Initializer_Job() {
    NODE_COUNT=$(get_worker_node_count)
    log "Detected $NODE_COUNT worker node(s) in the cluster."

    # A Job's pod template (spec.template) is immutable after creation -
    # unlike a Deployment/DaemonSet/StatefulSet, `kubectl apply` can never
    # update an existing Job in place; the API server rejects it outright
    # with "field is immutable". Every previous re-run of this script
    # happened to apply byte-identical Job specs, so this never surfaced -
    # confirmed live the first time this Job's spec actually changed between
    # two runs (adding the LOG_LEVEL env var): the apply failed, the script
    # didn't check its exit status, and it went on to wait on/report success
    # for the OLD, already-completed Job instead of a fresh run - silently
    # skipping the IP re-sync entirely rather than erroring loudly. Delete
    # any existing Job first so apply always creates a genuinely fresh one.
    kubectl delete job vlan-ip-initializer -n kube-system --ignore-not-found --wait=true >/dev/null 2>&1

    if [ "$NODE_COUNT" -lt 3 ]; then
        log "Node count <$NODE_COUNT> is less than 3 setting the etcd endpoint accordingly..."
        export ETCD_ENDPOINTS="http://etcd-0.etcd.kube-system.svc.cluster.local:2379"
        envsubst '${ETCD_ENDPOINTS}' < 05-vlan-ip-initializer-job.yaml | kubectl apply -f -
        unset ETCD_ENDPOINTS
    else
        log "Node count is $NODE_COUNT setting the etcd endpoint accordingly..."
        export ETCD_ENDPOINTS="http://etcd-0.etcd.kube-system.svc.cluster.local:2379,http://etcd-1.etcd.kube-system.svc.cluster.local:2379,http://etcd-2.etcd.kube-system.svc.cluster.local:2379"
        envsubst '${ETCD_ENDPOINTS}' < 05-vlan-ip-initializer-job.yaml | kubectl apply -f -
        unset ETCD_ENDPOINTS
    fi
}

# === setting the etcd endpoint in vlan ip controller deployment based on node count ===
Apply_etcd_endpoint_vlan_ip_controller_deployment() {
    NODE_COUNT=$(get_worker_node_count)
    log "Detected $NODE_COUNT worker node(s) in the cluster."

    if [ "$NODE_COUNT" -lt 3 ]; then
        log "Node count <$NODE_COUNT> is less than 3 setting the etcd endpoint accordingly..."
        export ETCD_ENDPOINTS="http://etcd-0.etcd.kube-system.svc.cluster.local:2379"
        envsubst '${ETCD_ENDPOINTS}' < 06-vlan-ip-controller-deployment.yaml | kubectl apply -f -
        unset ETCD_ENDPOINTS
    else
        log "Node count is $NODE_COUNT setting the etcd endpoint accordingly..."
        export ETCD_ENDPOINTS="http://etcd-0.etcd.kube-system.svc.cluster.local:2379,http://etcd-1.etcd.kube-system.svc.cluster.local:2379,http://etcd-2.etcd.kube-system.svc.cluster.local:2379"
        envsubst '${ETCD_ENDPOINTS}' < 06-vlan-ip-controller-deployment.yaml | kubectl apply -f -
        unset ETCD_ENDPOINTS
    fi
}

# === setting the etcd endpoint in vlan-manager daemonset based on node count ===
Create_vlan_manager_daemonset() {
    NODE_COUNT=$(get_worker_node_count)
    log "Detected $NODE_COUNT worker node(s) in the cluster."

    if [ "$NODE_COUNT" -lt 3 ]; then
        log "Node count <$NODE_COUNT> is less than 3 setting the etcd endpoint accordingly..."
        export ETCD_ENDPOINTS="http://etcd-0.etcd.kube-system.svc.cluster.local:2379"
        envsubst '${ETCD_ENDPOINTS}' < 07-vlan-manager-daemonset.yaml | kubectl apply -f -
        unset ETCD_ENDPOINTS
    else
        log "Node count is $NODE_COUNT setting the etcd endpoint accordingly..."
        export ETCD_ENDPOINTS="http://etcd-0.etcd.kube-system.svc.cluster.local:2379,http://etcd-1.etcd.kube-system.svc.cluster.local:2379,http://etcd-2.etcd.kube-system.svc.cluster.local:2379"
        envsubst '${ETCD_ENDPOINTS}' < 07-vlan-manager-daemonset.yaml | kubectl apply -f -
        unset ETCD_ENDPOINTS
    fi
}

#############################################
# Read value from vlan-manager ConfigMap
#############################################
get_cm_value() {
  local key="$1"

  kubectl -n kube-system get configmap vlan-manager-config \
    -o "jsonpath={.data.${key}}" 2>/dev/null || true
}

#############################################
# Detects whether this cluster has already been through
# post-migration-consolidate.sh - i.e. etcd is scheduled via the
# vlan-ready nodeAffinity pattern rather than the infra-pool nodeSelector.
#
# Found live, the hard way: without this check, simply re-running this
# orchestration script on an already-migrated cluster (a completely normal
# thing to do - it's meant to be idempotent and safe to re-run any time)
# silently UNDOES the migration for CoreDNS and every workload
# auto_pin_lke_system_components() below pins - it re-patches them straight
# back onto infra-pool, fighting a migration you already deliberately
# completed. install_kyverno()'s own pinning has the same unconditional
# "always re-patch to infra-pool" behavior for the same underlying reason
# (it needs to run every time to handle a sibling project installing
# Kyverno first - see its own comment) - callers of *this* guard exist so
# CoreDNS/the other LKE-system workloads don't share that same blind spot.
#
# etcd is the signal because it's the one workload post-migration-
# consolidate.sh unconditionally always re-applies with a nodeAffinity
# (never a nodeSelector) - if it exists and its current live spec has no
# infra-pool nodeSelector, this cluster has migrated. If etcd doesn't
# exist yet (fresh install, this function running for the first time
# ever) or still has the infra-pool nodeSelector, migration has NOT
# happened - proceed with pinning as normal.
#############################################
infra_pool_migration_already_done() {
  if ! kubectl get statefulset etcd -n kube-system >/dev/null 2>&1; then
    return 1
  fi
  local current_pin
  current_pin="$(kubectl get statefulset etcd -n kube-system -o jsonpath='{.spec.template.spec.nodeSelector.infra-pool}' 2>/dev/null)"
  [[ "$current_pin" != "true" ]]
}

#############################################
# Auto-pin CoreDNS to infra-pool.
#
# Runs after infra-pool is confirmed present (auto-created or manually
# created + labeled via ensure_infra_pool below), and before etcd/
# vlan-config-controller are deployed - see docs/DEPLOYMENT.md
# Installation step 2 for why the ordering matters: this patch triggers
# a CoreDNS rolling restart, and if etcd/the controller are already up
# and depending on DNS when that happens, the disruption can cascade.
#
# Auto-detects the actual Deployment name/namespace rather than assuming
# "coredns" - Standard LKE and LKE Enterprise differ (workload-coredns
# vs coredns), and this deliberately excludes coredns-autoscaler (it
# only adjusts replica count via the scale subresource, doesn't need
# pinning, and patching it would be at best pointless).
#
# Callers must check infra_pool_migration_already_done() first (see that
# function's comment) - this one doesn't check it itself so it stays
# usable standalone (e.g. from the DAY2-OPERATIONS.md manual-retrofit
# recipe, on a cluster that's deliberately not migrated).
#############################################
auto_pin_coredns() {
  log "Looking for the CoreDNS deployment to auto-pin to infra-pool..."

  if ! command -v jq >/dev/null 2>&1; then
    log "jq not found - skipping automatic CoreDNS pinning. Pin it manually per docs/DEPLOYMENT.md Installation step 2."
    return 0
  fi

  local matches
  matches="$(kubectl get deployments -A -o json 2>/dev/null | jq -r '
    .items[]
    | select(.metadata.name | test("coredns"; "i"))
    | select(.metadata.name | test("autoscaler"; "i") | not)
    | "\(.metadata.namespace)/\(.metadata.name)"
  ')"

  local match_count
  match_count="$(echo "$matches" | grep -c . || true)"

  if [[ "$match_count" -eq 0 ]]; then
    log "No CoreDNS deployment found automatically. Pin it manually per docs/DEPLOYMENT.md Installation step 2."
    return 0
  fi

  if [[ "$match_count" -gt 1 ]]; then
    log "Found multiple possible CoreDNS deployments - not auto-pinning to avoid patching the wrong one: $(echo "$matches" | tr '\n' ' '). Pin the correct one manually per docs/DEPLOYMENT.md Installation step 2."
    return 0
  fi

  local coredns_ns coredns_deploy
  coredns_ns="${matches%%/*}"
  coredns_deploy="${matches##*/}"

  local current_pin
  current_pin="$(kubectl get deployment "$coredns_deploy" -n "$coredns_ns" -o jsonpath='{.spec.template.spec.nodeSelector.infra-pool}' 2>/dev/null)"
  if [[ "$current_pin" == "true" ]]; then
    log "${coredns_ns}/${coredns_deploy} already pinned to infra-pool. Nothing to do."
    return 0
  fi

  log "Pinning ${coredns_ns}/${coredns_deploy} to infra-pool (this triggers a CoreDNS rolling restart - brief DNS disruption while it reschedules, same as the documented manual step)..."
  if ! kubectl patch deployment "$coredns_deploy" -n "$coredns_ns" --type merge -p \
    '{"spec":{"template":{"spec":{"nodeSelector":{"infra-pool":"true"},"tolerations":[{"key":"infra-pool","operator":"Equal","value":"true","effect":"NoSchedule"}]}}}}' >/dev/null 2>&1; then
    log "Failed to patch ${coredns_ns}/${coredns_deploy}. Pin it manually per docs/DEPLOYMENT.md Installation step 2."
    return 0
  fi

  kubectl rollout status deployment/"$coredns_deploy" -n "$coredns_ns" --timeout=300s
  log "CoreDNS (${coredns_ns}/${coredns_deploy}) pinned to infra-pool."
}

#############################################
# Auto-pin the other LKE-managed kube-system workloads that, like
# CoreDNS, ship with no tolerations of their own and therefore have
# nowhere to schedule once both node pools carry custom taints from the
# start (this project's documented default setup - see docs/DEPLOYMENT.md
# "Why a dedicated infra-pool node pool").
#
# Found live, the hard way, on a real cluster: cilium-operator has no
# DaemonSet-style implicit taint tolerance the way cilium's own per-node
# agent does - with nowhere to schedule, it never registers Cilium's CRDs,
# every cilium agent pod stays stuck in CrashLoopBackOff waiting on those
# CRDs, and NO NODE IN THE CLUSTER EVER BECOMES READY. This is a strictly
# worse failure mode than a single stuck Deployment (see e.g. csi-linode-
# controller below) - it's a full deadlock, confirmed by reproducing it
# end-to-end on a fresh LKE Enterprise cluster. The same class of gap hits
# calico-kube-controllers/calico-typha-autoscaler on LKE Standard (Calico
# instead of Cilium) and konnectivity-agent/konnectivity-autoscaler/
# coredns-autoscaler/csi-linode-controller on both cluster types - all
# confirmed stuck Pending on real clusters this same way, just without the
# full-deadlock severity of cilium-operator specifically.
#
# Every name below is checked defensively (kubectl get ... || continue)
# before patching, since which of these exist depends on cluster type
# (Standard/Calico vs Enterprise/Cilium) and LKE version - this function
# is deliberately a superset covering both, not a per-type branch, so it
# stays correct without needing to know LKE_CLUSTER_TYPE at all.
#############################################
LKE_SYSTEM_DEPLOYMENTS_NEEDING_PIN=(
  cilium-operator
  calico-kube-controllers
  calico-typha-autoscaler
  coredns-autoscaler
  konnectivity-agent
  # The konnectivity autoscaler's Deployment name is NOT consistent across
  # cluster types - confirmed live: "konnectivity-autoscaler" on LKE
  # Enterprise, but "konnectivity-agent-autoscaler" on LKE Standard. Missing
  # this the first time round left it with zero tolerations for either
  # pool's taint and stuck Pending indefinitely on Standard - the
  # kubectl-get-or-continue guard below only skips a name that doesn't
  # exist, it can't detect "exists under a different name", so both must be
  # listed explicitly rather than picking one.
  konnectivity-autoscaler
  konnectivity-agent-autoscaler
)
LKE_SYSTEM_STATEFULSETS_NEEDING_PIN=(
  csi-linode-controller
)

auto_pin_lke_system_components() {
  log "Checking for other LKE-managed kube-system workloads that need pinning to infra-pool (cilium-operator, calico controllers, konnectivity, csi-linode-controller, etc. - see comment above)..."

  local patch='{"spec":{"template":{"spec":{"nodeSelector":{"infra-pool":"true"},"tolerations":[{"key":"infra-pool","operator":"Equal","value":"true","effect":"NoSchedule"}]}}}}'
  local name
  local -a pending_deployments=()
  local -a pending_statefulsets=()

  # Phase 1: issue every patch up front - patching is fast and each item is
  # independent of the others. The slow part (waiting for the resulting
  # rollout, which can take minutes per workload) is deferred to phase 2
  # below, where every wait runs concurrently instead of one after another.
  # On a cluster that needs several of these pinned at once, this turns N
  # sequential multi-minute rollout waits into roughly one wait's worth of
  # wall-clock time (confirmed live: pinning konnectivity-agent and
  # konnectivity-autoscaler alone took ~6 minutes sequentially).
  for name in "${LKE_SYSTEM_DEPLOYMENTS_NEEDING_PIN[@]}"; do
    if ! kubectl get deployment "$name" -n kube-system >/dev/null 2>&1; then
      continue
    fi
    local current_pin
    current_pin="$(kubectl get deployment "$name" -n kube-system -o jsonpath='{.spec.template.spec.nodeSelector.infra-pool}' 2>/dev/null)"
    if [[ "$current_pin" == "true" ]]; then
      log "kube-system/${name} already pinned to infra-pool. Nothing to do."
      continue
    fi
    log "Pinning kube-system/${name} to infra-pool..."
    if kubectl patch deployment "$name" -n kube-system --type merge -p "$patch" >/dev/null 2>&1; then
      pending_deployments+=("$name")
    else
      log "Failed to patch kube-system/${name} - pin it manually (same nodeSelector/toleration pattern as CoreDNS, see docs/DEPLOYMENT.md Installation step 2)."
    fi
  done

  for name in "${LKE_SYSTEM_STATEFULSETS_NEEDING_PIN[@]}"; do
    if ! kubectl get statefulset "$name" -n kube-system >/dev/null 2>&1; then
      continue
    fi
    local current_pin
    current_pin="$(kubectl get statefulset "$name" -n kube-system -o jsonpath='{.spec.template.spec.nodeSelector.infra-pool}' 2>/dev/null)"
    if [[ "$current_pin" == "true" ]]; then
      log "kube-system/${name} already pinned to infra-pool. Nothing to do."
      continue
    fi
    log "Pinning kube-system/${name} to infra-pool..."
    if kubectl patch statefulset "$name" -n kube-system --type merge -p "$patch" >/dev/null 2>&1; then
      # StatefulSets don't recreate an already-Pending pod on template
      # change by themselves - force it so this actually takes effect now,
      # not just on this workload's next unrelated restart.
      kubectl delete pod -n kube-system -l app="$name" --ignore-not-found >/dev/null 2>&1 || true
      pending_statefulsets+=("$name")
    else
      log "Failed to patch kube-system/${name} - pin it manually (same nodeSelector/toleration pattern as CoreDNS, see docs/DEPLOYMENT.md Installation step 2)."
    fi
  done

  # Phase 2: wait for every rollout triggered above, concurrently rather
  # than one at a time.
  local -a wait_pids=()
  local -a wait_names=()
  for name in "${pending_deployments[@]}"; do
    kubectl rollout status deployment/"$name" -n kube-system --timeout=180s >/dev/null 2>&1 &
    wait_pids+=("$!")
    wait_names+=("$name")
  done
  for name in "${pending_statefulsets[@]}"; do
    kubectl rollout status statefulset/"$name" -n kube-system --timeout=180s >/dev/null 2>&1 &
    wait_pids+=("$!")
    wait_names+=("$name")
  done

  local i
  for i in "${!wait_pids[@]}"; do
    if wait "${wait_pids[$i]}"; then
      log "kube-system/${wait_names[$i]} pinned to infra-pool."
    else
      log "kube-system/${wait_names[$i]} rollout did not finish within the timeout - it was patched, but may still be rolling out or stuck. Check manually: kubectl rollout status deployment/${wait_names[$i]} -n kube-system"
    fi
  done
}

#############################################
# Ensure infra-pool exists, is labeled/tainted correctly, and CoreDNS is
# pinned to it - either by creating the pool automatically
# (AUTO_CREATE_INFRA_POOL="true", requires INFRA_POOL_PLAN) or by
# labeling/tainting a pool you already created yourself (INFRA_POOL_ID).
#
# Deliberately opt-in, unlike ensure_app_pool_taint below: creating a
# node pool provisions real, billed Linode instances - a materially
# bigger action than modifying an existing resource's taints/labels,
# and not something that should happen as a silent side effect of
# running a deploy script. Node TYPE/plan is also a genuine cost/region
# choice this script has no safe way to guess - it has to come from
# INFRA_POOL_PLAN, never a hardcoded default.
#
# Idempotent either way: detects an already-labeled infra-pool and skips
# straight to the CoreDNS pin. Safe to leave AUTO_CREATE_INFRA_POOL="true"
# permanently - the pool only ever gets created once.
#############################################
INFRA_POOL_LABEL_KEY="infra-pool"
INFRA_POOL_TAINT_KEY="infra-pool"
INFRA_POOL_MIN_NODES=3

#############################################
# Wraps `linode-cli` for LKE pool operations (pools-list/pool-create/
# pool-update). On LKE_CLUSTER_TYPE=enterprise, POST/PUT (and possibly
# other) calls against the stable /v4/lke/clusters/{id}/pools endpoint are
# rejected outright:
#   "Method POST on endpoint '/v4/clusters/<id>/pools' is disabled for
#   Enterprise clusters. Please use '/v4beta/clusters/<id>/pools' endpoint
#   instead."
# LINODE_CLI_API_VERSION=v4beta (a real linode-cli env override - see
# linodecli/helpers.py's handle_url_overrides()) repoints every call the
# wrapped command makes at /v4beta instead of /v4. v4beta is a strict
# superset of v4, so it's safe to use unconditionally for GET calls too -
# this keeps every pool call for a given cluster on one consistent API
# version rather than only switching it for the calls that happen to fail.
#############################################
lke_cli() {
  local cluster_type
  cluster_type="$(get_cm_value LKE_CLUSTER_TYPE | tr '[:upper:]' '[:lower:]')"
  if [[ "$cluster_type" == "enterprise" ]]; then
    LINODE_CLI_API_VERSION=v4beta linode-cli "$@"
  else
    linode-cli "$@"
  fi
}

ensure_infra_pool() {
  if ! command -v linode-cli >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    log "linode-cli and/or jq not found locally - skipping automatic infra-pool setup. Create/verify infra-pool and pin CoreDNS manually per docs/DEPLOYMENT.md Installation steps 1-2."
    return 0
  fi

  local lke_cluster_id
  lke_cluster_id="$(get_cm_value LKE_CLUSTER_ID)"
  if [[ -z "$lke_cluster_id" ]]; then
    log "LKE_CLUSTER_ID not set - skipping automatic infra-pool setup."
    return 0
  fi

  local auto_create
  auto_create="$(get_cm_value AUTO_CREATE_INFRA_POOL | tr '[:upper:]' '[:lower:]')"

  local pools_json
  pools_json="$(lke_cli lke pools-list "$lke_cluster_id" --json 2>/dev/null)"

  # Idempotency check first, regardless of AUTO_CREATE_INFRA_POOL - does a
  # pool already carry the infra-pool=true label, however it got there?
  local existing_pool_id=""
  if [[ -n "$pools_json" && "$pools_json" != "[]" ]]; then
    existing_pool_id="$(echo "$pools_json" | jq -r --arg k "$INFRA_POOL_LABEL_KEY" '.[] | select(.labels[$k]=="true") | .id' | head -n1)"
  fi

  local pool_id=""

  if [[ -n "$existing_pool_id" && "$existing_pool_id" != "null" ]]; then
    log "infra-pool already exists and is labeled (id=${existing_pool_id})."
    pool_id="$existing_pool_id"

  elif [[ "$auto_create" == "true" ]]; then
    log "AUTO_CREATE_INFRA_POOL=true and no labeled infra-pool found - creating one..."

    local plan node_count
    plan="$(get_cm_value INFRA_POOL_PLAN)"
    node_count="$(get_cm_value INFRA_POOL_NODE_COUNT)"
    node_count="${node_count:-3}"

    if [[ -z "$plan" ]]; then
      log "AUTO_CREATE_INFRA_POOL=true but INFRA_POOL_PLAN is not set. Set it in the ConfigMap (e.g. g6-standard-2 - see \`linode-cli linodes types\`) and re-run, or create infra-pool manually per docs/DEPLOYMENT.md Installation step 1."
      return 1
    fi

    if [[ "$node_count" -lt "$INFRA_POOL_MIN_NODES" ]]; then
      log "INFRA_POOL_NODE_COUNT=${node_count} is below the minimum of ${INFRA_POOL_MIN_NODES} - etcd's pod anti-affinity requires at least ${INFRA_POOL_MIN_NODES} distinct infra-pool nodes to ever fully schedule. Raise INFRA_POOL_NODE_COUNT and re-run."
      return 1
    fi

    local create_output create_err
    create_err="$(mktemp)"
    create_output="$(lke_cli lke pool-create "$lke_cluster_id" --type "$plan" --count "$node_count" \
      --labels "{\"${INFRA_POOL_LABEL_KEY}\":\"true\"}" \
      --taints.key "$INFRA_POOL_TAINT_KEY" --taints.value true --taints.effect NoSchedule \
      --json 2>"$create_err")"

    pool_id="$(echo "$create_output" | jq -r '.[0].id // .id // empty' 2>/dev/null)"

    if [[ -z "$pool_id" ]]; then
      log "Failed to create infra-pool automatically. linode-cli error:"
      log "   $(cat "$create_err")"
      log "   Common causes: INFRA_POOL_PLAN='${plan}' isn't a valid/available type id (see \`linode-cli linodes types\`), or the token in 00-vlan-manager-secret.yaml lacks permission to modify this cluster's pools."
      log "   Fix the ConfigMap value and re-run, or create infra-pool manually per docs/DEPLOYMENT.md Installation step 1."
      rm -f "$create_err"
      return 1
    fi
    rm -f "$create_err"

    log "infra-pool created (id=${pool_id}, type=${plan}, count=${node_count}). Waiting for its nodes to join the cluster..."
    local wait_attempt
    for wait_attempt in $(seq 1 60); do
      local joined
      joined="$(kubectl get nodes -l infra-pool=true --no-headers 2>/dev/null | wc -l)"
      if [[ "$joined" -ge "$node_count" ]]; then
        log "All ${node_count} infra-pool node(s) have joined the cluster."
        break
      fi
      sleep 10
    done

  else
    local manual_pool_id
    manual_pool_id="$(get_cm_value INFRA_POOL_ID)"

    if [[ -z "$manual_pool_id" ]]; then
      log "AUTO_CREATE_INFRA_POOL=false and INFRA_POOL_ID is not set - skipping automatic infra-pool label/taint setup. Set INFRA_POOL_ID in the ConfigMap to the pool id you created manually, or apply the label/taint yourself per docs/DEPLOYMENT.md Installation step 1."
      return 0
    fi

    if [[ -z "$pools_json" || "$pools_json" == "[]" ]]; then
      log "Could not list node pools for cluster ${lke_cluster_id}. Check INFRA_POOL_ID manually per docs/DEPLOYMENT.md Installation step 1."
      return 0
    fi

    log "Applying infra-pool label/taint to manually-created pool id=${manual_pool_id}..."

    local existing_labels existing_taints
    existing_labels="$(echo "$pools_json" | jq -c --arg id "$manual_pool_id" '.[] | select((.id|tostring)==$id) | .labels // {}')"
    existing_taints="$(echo "$pools_json" | jq -c --arg id "$manual_pool_id" '.[] | select((.id|tostring)==$id) | .taints // []')"

    if [[ -z "$existing_labels" ]]; then
      log "Could not find a pool with id=${manual_pool_id} on cluster ${lke_cluster_id}. Check INFRA_POOL_ID in the ConfigMap."
      return 1
    fi

    local current_count
    current_count="$(echo "$pools_json" | jq -r --arg id "$manual_pool_id" '.[] | select((.id|tostring)==$id) | .count')"
    if [[ -n "$current_count" && "$current_count" != "null" && "$current_count" -lt "$INFRA_POOL_MIN_NODES" ]]; then
      log "infra-pool (id=${manual_pool_id}) has only ${current_count} node(s) - etcd's pod anti-affinity needs at least ${INFRA_POOL_MIN_NODES} distinct nodes to fully schedule. Resize this pool before deploying etcd."
    fi

    local already_labeled already_tainted
    already_labeled="$(echo "$existing_labels" | jq -r --arg k "$INFRA_POOL_LABEL_KEY" '.[$k] // empty')"
    if echo "$existing_taints" | jq -e --arg k "$INFRA_POOL_TAINT_KEY" 'any(.[]?; .key==$k)' >/dev/null 2>&1; then
      already_tainted="true"
    else
      already_tainted="false"
    fi

    if [[ "$already_labeled" == "true" && "$already_tainted" == "true" ]]; then
      log "infra-pool (id=${manual_pool_id}) already has both the label and taint. Nothing to do."
      pool_id="$manual_pool_id"
    else
      # Merge: keep every existing label/taint, add ours only if missing -
      # same non-destructive principle as ensure_app_pool_taint below,
      # since pool-update replaces both fields wholesale.
      local merged_labels merged_taints
      merged_labels="$(echo "$existing_labels" | jq -c --arg k "$INFRA_POOL_LABEL_KEY" '. + {($k):"true"}')"
      merged_taints="$(echo "$existing_taints" | jq -c --arg k "$INFRA_POOL_TAINT_KEY" \
        'if any(.[]?; .key==$k) then . else (. // []) + [{"key":$k,"value":"true","effect":"NoSchedule"}] end')"

      local taint_args=()
      local taint_count
      taint_count="$(echo "$merged_taints" | jq 'length' 2>/dev/null || echo 0)"
      local i k v e
      for ((i = 0; i < taint_count; i++)); do
        k="$(echo "$merged_taints" | jq -r ".[$i].key")"
        v="$(echo "$merged_taints" | jq -r ".[$i].value")"
        e="$(echo "$merged_taints" | jq -r ".[$i].effect")"
        taint_args+=(--taints.key "$k" --taints.value "$v" --taints.effect "$e")
      done

      if lke_cli lke pool-update "$lke_cluster_id" "$manual_pool_id" \
        --labels "$merged_labels" "${taint_args[@]}" >/dev/null; then
        log "infra-pool (id=${manual_pool_id}) now has the '${INFRA_POOL_LABEL_KEY}' label and '${INFRA_POOL_TAINT_KEY}' taint, all pre-existing labels/taints preserved."
        pool_id="$manual_pool_id"
      else
        log "Failed to update infra-pool label/taint automatically. Check/fix manually: linode-cli lke pools-list ${lke_cluster_id} --json | jq '.[] | {id, taints, labels}' — see docs/DEPLOYMENT.md Installation step 1."
        return 1
      fi
    fi
  fi

  if [[ -n "$pool_id" ]]; then
    if infra_pool_migration_already_done; then
      log "This cluster has already been through post-migration-consolidate.sh (etcd is on vlan-ready, not infra-pool) - skipping CoreDNS/LKE-system-component pinning so this run doesn't fight that migration. See infra_pool_migration_already_done()'s comment."
    else
      auto_pin_coredns
      auto_pin_lke_system_components
    fi
  fi
}

#############################################
# Ensure the app-pool has the vlan-not-ready taint, preserving any
# taints already there from other projects (e.g. lke-e-acl-operator's
# acl-not-ready) - so this project's deploy never has to know or care
# whether it's running first, second, or Nth on this cluster.
#
# The app-pool is found via its "app-pool=true" LABEL (the same
# discovery convention infra-pool already uses), not by name or by
# assuming it's "whichever pool isn't infra-pool" - Linode pools have no
# inherent identity beyond a numeric id, so a label is the only reliable
# way to find it via the API. See docs/DEPLOYMENT.md Installation step 1
# for where this label gets set the first time (pool-create/pool-update).
#
# `pool-update` REPLACES a pool's taints array wholesale - there is no
# partial-add API call - so this always reads the pool's current taints
# first and resubmits the full set (everyone else's plus this project's
# own) in one call. This is what makes the "combine taints in one
# pool-update call" step from earlier in this project's history
# unnecessary to do by hand: this function IS that combine-and-call
# step, just run automatically, every deploy, by whichever project's
# script gets there - so it's correct regardless of which order any
# number of projects actually deploy in.
#
# Soft-fails (warns and returns 0, doesn't abort the deployment) if
# linode-cli/jq aren't available locally or LKE_CLUSTER_ID isn't set -
# falling back to the manual procedure in docs/DEPLOYMENT.md Installation
# step 1 keeps this from breaking deployments that predate this function.
#############################################
APP_POOL_LABEL_KEY="app-pool"
APP_POOL_TAINT_KEY="vlan-not-ready"

# Ensures ONE pool (by id, already confirmed to carry the app-pool=true
# label) has the vlan-not-ready taint, merging it into whatever taints
# already exist there rather than replacing the list - see the header
# comment above ensure_app_pool_taint() for why this matters. Split out
# from ensure_app_pool_taint() so multiple app-pools (see APP_POOL_ID below)
# can each go through the exact same merge-safe logic in a loop.
_ensure_taint_on_one_pool() {
  local lke_cluster_id="$1" pool_id="$2" pools_json="$3"

  local existing_taints
  existing_taints="$(echo "$pools_json" | jq -c --arg id "$pool_id" '.[] | select((.id|tostring)==$id) | .taints')"

  if echo "$existing_taints" | jq -e --arg k "$APP_POOL_TAINT_KEY" 'any(.[]; .key==$k)' >/dev/null 2>&1; then
    log "App-pool (id=${pool_id}) already has the '${APP_POOL_TAINT_KEY}' taint. Nothing to do."
    return 0
  fi

  local taint_names
  taint_names="$(echo "$existing_taints" | jq -c '[.[].key]' 2>/dev/null || echo "[]")"
  log "App-pool (id=${pool_id}) is missing '${APP_POOL_TAINT_KEY}' - merging it in alongside its existing taint(s) ${taint_names} via a single pool-update call, so nothing already there (including another project's own taint) gets dropped..."

  local taint_args=()
  local taint_count
  taint_count="$(echo "$existing_taints" | jq 'length' 2>/dev/null || echo 0)"
  local i k v e
  for ((i = 0; i < taint_count; i++)); do
    k="$(echo "$existing_taints" | jq -r ".[$i].key")"
    v="$(echo "$existing_taints" | jq -r ".[$i].value")"
    e="$(echo "$existing_taints" | jq -r ".[$i].effect")"
    taint_args+=(--taints.key "$k" --taints.value "$v" --taints.effect "$e")
  done
  taint_args+=(--taints.key "$APP_POOL_TAINT_KEY" --taints.value "true" --taints.effect "NoSchedule")

  if lke_cli lke pool-update "$lke_cluster_id" "$pool_id" "${taint_args[@]}" >/dev/null; then
    log "App-pool (id=${pool_id}) now has '${APP_POOL_TAINT_KEY}', all pre-existing taints preserved."
  else
    log "Failed to update app-pool taints automatically for pool id=${pool_id}. Check/fix manually: linode-cli lke pools-list ${lke_cluster_id} --json | jq '.[] | {id, taints, labels}' — see docs/DEPLOYMENT.md Installation step 1."
  fi
}

ensure_app_pool_taint() {
  local kyverno_enabled
  kyverno_enabled="$(get_cm_value ENABLE_KYVERNO | tr '[:upper:]' '[:lower:]')"
  if [[ "${kyverno_enabled}" != "true" ]]; then
    log "ENABLE_KYVERNO is not true - skipping automatic app-pool taint check. Without Kyverno's ClusterPolicy to grant the matching toleration to ordinary pods, adding this taint automatically would just block scheduling with no automatic remedy. Set it manually per docs/DEPLOYMENT.md Installation step 1 if you still want the taint without the Kyverno gate."
    return 0
  fi

  log "Ensuring every app-pool (discovered via '${APP_POOL_LABEL_KEY}=true' label, plus any pool listed in APP_POOL_ID not yet labeled) has the '${APP_POOL_TAINT_KEY}' taint, preserving any taint already there from another project..."

  if ! command -v linode-cli >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    log "linode-cli and/or jq not found locally - skipping automatic app-pool taint check. Set/verify the '${APP_POOL_TAINT_KEY}' taint manually per docs/DEPLOYMENT.md Installation step 1 (combine with any other project's taint already on that pool)."
    return 0
  fi

  local lke_cluster_id
  lke_cluster_id="$(get_cm_value LKE_CLUSTER_ID)"
  if [[ -z "$lke_cluster_id" ]]; then
    log "LKE_CLUSTER_ID not set in vlan-manager-config - skipping automatic app-pool taint check. Set it manually per docs/DEPLOYMENT.md Installation step 1."
    return 0
  fi

  local pools_json
  pools_json="$(lke_cli lke pools-list "$lke_cluster_id" --json 2>/dev/null)"
  if [[ -z "$pools_json" || "$pools_json" == "[]" ]]; then
    log "Could not list node pools for cluster ${lke_cluster_id} (or none exist yet). Create the app-pool manually first - see docs/DEPLOYMENT.md Installation step 1 (must include --labels '{\"${APP_POOL_LABEL_KEY}\":\"true\"}')."
    return 0
  fi

  # Every pool that ALREADY carries the label - a cluster can legitimately
  # have more than one app-pool (e.g. different instance types for
  # different workloads), and every one of them needs this taint, not just
  # whichever one happens to be listed first.
  local labeled_pool_ids
  labeled_pool_ids="$(echo "$pools_json" | jq -r --arg k "$APP_POOL_LABEL_KEY" '[.[] | select(.labels[$k]=="true") | (.id|tostring)]')"

  # Bootstrap fallback: APP_POOL_ID is a comma-separated list of pool ids
  # (one id is still valid - a plain scalar is just a one-element list) for
  # pools the user already created but that don't carry the label yet. Each
  # one gets the label applied automatically (one-time only - see
  # docs/DEPLOYMENT.md Installation step 1) instead of making the user
  # hand-construct the pool-update --labels/--taints.* syntax themselves,
  # same rationale as ensure_infra_pool()'s INFRA_POOL_ID path. This is
  # bootstrap-only: once a pool's label exists, every later run (this
  # project's or a sibling's) finds it via the label itself, never via
  # APP_POOL_ID - that has to stay true for sibling projects, which have no
  # knowledge of this ConfigMap.
  local app_pool_id_csv
  app_pool_id_csv="$(get_cm_value APP_POOL_ID)"

  local all_pool_ids
  all_pool_ids="$labeled_pool_ids"

  if [[ -n "$app_pool_id_csv" ]]; then
    local raw_id trimmed_id
    # Split on commas; IFS-based `read` also trims each field's surrounding
    # whitespace so "id1, id2 , id3" works the same as "id1,id2,id3".
    IFS=',' read -ra _app_pool_ids <<< "$app_pool_id_csv"
    for raw_id in "${_app_pool_ids[@]}"; do
      trimmed_id="$(echo "$raw_id" | xargs)"
      [[ -z "$trimmed_id" ]] && continue

      if echo "$all_pool_ids" | jq -e --arg id "$trimmed_id" 'any(.[]; .==$id)' >/dev/null 2>&1; then
        continue   # already labeled (found above, or an earlier id in this same list) - nothing to bootstrap
      fi

      local app_pool_labels
      app_pool_labels="$(echo "$pools_json" | jq -c --arg id "$trimmed_id" '.[] | select((.id|tostring)==$id) | .labels // {}')"

      if [[ -z "$app_pool_labels" ]]; then
        log "APP_POOL_ID entry '${trimmed_id}' does not match any node pool on cluster ${lke_cluster_id}. Check the value and re-run, or see docs/DEPLOYMENT.md Installation step 1."
        continue
      fi

      log "APP_POOL_ID entry '${trimmed_id}' set and not yet labeled '${APP_POOL_LABEL_KEY}=true' - applying the label now..."

      local merged_app_pool_labels
      merged_app_pool_labels="$(echo "$app_pool_labels" | jq -c --arg k "$APP_POOL_LABEL_KEY" '. + {($k):"true"}')"

      # --labels-only call, deliberately no --taints.* here - confirmed
      # elsewhere in this project that --labels and --taints.* are
      # independent fields on this endpoint (a pool-update that omits
      # --taints.* leaves existing taints untouched), so this can't
      # accidentally wipe out a taint another project already placed here.
      # The taint itself is handled by _ensure_taint_on_one_pool() below.
      if ! lke_cli lke pool-update "$lke_cluster_id" "$trimmed_id" --labels "$merged_app_pool_labels" >/dev/null; then
        log "Failed to apply the '${APP_POOL_LABEL_KEY}=true' label to pool id=${trimmed_id}. Check/fix manually: linode-cli lke pools-list ${lke_cluster_id} --json | jq '.[] | {id, taints, labels}' — see docs/DEPLOYMENT.md Installation step 1."
        continue
      fi

      log "Pool id=${trimmed_id} now labeled '${APP_POOL_LABEL_KEY}=true'."
      all_pool_ids="$(echo "$all_pool_ids" | jq -c --arg id "$trimmed_id" '. + [$id]')"
    done
  fi

  local pool_count
  pool_count="$(echo "$all_pool_ids" | jq 'length')"

  if [[ "$pool_count" -eq 0 ]]; then
    log "No node pool labeled '${APP_POOL_LABEL_KEY}=true' found on cluster ${lke_cluster_id}, and APP_POOL_ID is not set. Either add the label by hand (see docs/DEPLOYMENT.md Installation step 1) or set APP_POOL_ID in the ConfigMap to the pool id(s) you already created (comma-separated for more than one), then re-run - this function will apply the label (and taint) for you automatically. Skipping automatic taint check for now."
    return 0
  fi

  local pid
  for pid in $(echo "$all_pool_ids" | jq -r '.[]'); do
    _ensure_taint_on_one_pool "$lke_cluster_id" "$pid" "$pools_json"
  done
}

# === Preflight: required local config files ===
# Both files below are gitignored and must be created locally by copying
# their .example.template.yaml counterpart before running this script.
for required_file in 00-vlan-manager-configmap.yaml 00-vlan-manager-secret.yaml; do
    if [[ ! -f "$required_file" ]]; then
        echo "Missing $required_file."
        echo "   Create it from the template first, e.g.:"
        echo "     cp ${required_file%.yaml}.example.template.yaml $required_file"
        echo "   Then edit $required_file and fill in real values before re-running this script."
        exit 1
    fi
done

# === Step 1: Apply StorageClass ===
echo "Checking for existing Linode Block StorageClass..."
if kubectl get storageclass linode-block-storage &> /dev/null; then
    echo "linode-block-storage already exists. Skipping creation."
else
    echo "Creating Linode Block StorageClass..."
    kubectl apply -f 01-linode-storageclass.yaml || exit 1
    echo "linode-block-storage created successfully."
fi

# === Step 2: Apply RBAC for VLAN Manager ===
echo "Applying RBAC for VLAN Manager..."
kubectl apply -f 03-vlan-manager-rbac.yaml || exit 1

# === Step 3: Apply ConfigMaps ===
echo "Applying ConfigMap for VLAN Manager Scripts..."
apply_vlan_manager_scripts_configmap

echo "Applying ConfigMap for VLAN Manager Configuration..."
kubectl apply -f 00-vlan-manager-configmap.yaml || exit 1

echo "Applying Secret for VLAN Manager (LINODE_API_KEY / LINODE_CLI_CONFIG)..."
kubectl apply -f 00-vlan-manager-secret.yaml || exit 1

# === Step 3.4: Ensure infra-pool exists (opt-in auto-create) or is    ===
# === labeled/tainted (if manually created), then auto-pin CoreDNS to  ===
# === it - before etcd/the controller come up and start depending on   ===
# === DNS, per docs/DEPLOYMENT.md Installation step 2                  ===
#
# ensure_infra_pool() returns 1 only on genuine failures that leave the
# cluster without a usable infra-pool (bad INFRA_POOL_PLAN, pool-create
# API error, pool-update failure, missing pool for a given INFRA_POOL_ID)
# - it returns 0 for legitimate soft-skips (linode-cli/jq missing,
# AUTO_CREATE_INFRA_POOL=false with no INFRA_POOL_ID set, etc). The script
# has no `set -e`, so without this explicit check a hard failure here was
# silently ignored and the deploy carried on straight into etcd/CoreDNS
# with no infra-pool nodes to schedule onto - etcd would then hang forever
# waiting for pods that can never be placed. Fail fast instead: this
# solution cannot run without a working infra-pool.
if ! ensure_infra_pool; then
    echo "infra-pool setup failed - see the error above. Deployment cannot continue without a working infra-pool (etcd/CoreDNS/Kyverno have nowhere to schedule)."
    exit 1
fi

# === Step 3.5: Ensure the app-pool's permanent taint is set, without ===
# === clobbering any other project's taint already on that pool     ===
ensure_app_pool_taint

# === Step 4: Creating ETCD deployment ===
echo "ETCD deployment initiated based on node count."
deploy_etcd_cluster

echo "Waiting for etcd pods to be registered in Kubernetes..."
while true; do
    etcd_pods=$(kubectl get pods -n kube-system -l app=etcd --no-headers 2>/dev/null | wc -l)
    if [ "$etcd_pods" -ge 1 ]; then
        echo "etcd pods found: $etcd_pods"
        break
    fi
    echo "etcd pods not found yet. Retrying in 5 seconds..."
    sleep 5
done

echo "Waiting for all etcd pods to become Ready..."
while true; do
    not_ready=$(kubectl get pods -n kube-system -l app=etcd --field-selector=status.phase!=Running --no-headers | wc -l)
    ready_count=$(kubectl get pods -n kube-system -l app=etcd --field-selector=status.phase=Running --no-headers | grep '1/1' | wc -l)
    total=$(kubectl get pods -n kube-system -l app=etcd --no-headers 2>/dev/null | wc -l)

    if [ "$total" -eq "$ready_count" ] && [ "$total" -gt 0 ]; then
        echo "All etcd pods are Ready. Total: $total"
        break
    fi

    echo "etcd pods not ready yet. Ready: $ready_count / Total: $total. Retrying in 5 seconds..."
    sleep 5
done

#############################################
# Deployment Mode Selection
#############################################

ENABLE_VLAN="$(get_cm_value ENABLE_VLAN | tr '[:upper:]' '[:lower:]')"

if [[ "${ENABLE_VLAN}" == "false" ]]; then
  log "ENABLE_VLAN=false → Running VPC-only mode"
  log "IP initializer, Leader Manager"

  # Step 7 – Kyverno
  ENABLE_KYVERNO="$(get_cm_value ENABLE_KYVERNO | tr '[:upper:]' '[:lower:]')"
  if [[ "${ENABLE_KYVERNO}" == "true" ]]; then
    install_kyverno || { log "Kyverno install failed"; exit 1; }
    apply_kyverno_policy || { log "Kyverno policy apply failed"; exit 1; }
  else
    log "Kyverno disabled → skipping"
  fi

  # === Step 8: Deploy vlan-config-controller Deployment ===
  echo "Deploying vlan-config-controller Deployment..."
  apply_vlan_config_controller

  # Step 9 – DaemonSet 
  echo "Deploying VLAN Manager DaemonSet..."
  Create_vlan_manager_daemonset
  
  # Wait for DaemonSet rollout
  echo "Waiting for VLAN Manager DaemonSet to be ready..."
  kubectl rollout status daemonset/vlan-manager -n kube-system
      
  # === Log command hints for DaemonSet Pods ===
  echo "Fetching VLAN Manager Pods..."
  PODS=$(kubectl get pods -n kube-system -l app=vlan-manager -o jsonpath='{.items[*].metadata.name}')
  
  if [ -z "$PODS" ]; then
      echo "No VLAN Manager pods found. Exiting..."
      exit 1
  fi  
      
  echo "VLAN Manager DaemonSet is fully deployed."
  echo "You can monitor the logs using the following commands:"
  for pod in $PODS; do
      echo "kubectl logs -f pod/$pod -n kube-system"
  done 
  
  echo "VLAN Leader Manager is up and running."
      
  echo "Orchestration Complete! VLAN Manager is fully operational."

  log "VPC-only deployment completed."
  DEPLOYMENT_SUCCESS="true"
  exit 0
fi

log "ENABLE_VLAN=true → Running Full VLAN Mode"

# Continue normal flow:
# Step 4 – ETCD
# Step 5 – Initializer
# Step 6 – Leader Manager
# Step 7 – Kyverno
# Step 8 – DaemonSet



# === Step 5: Apply Initializer Job ===
echo "Launching VLAN IP Initializer Job..."
Apply_Initializer_Job

# Wait for Job to appear in Kubernetes
echo "Waiting for Initializer Job to be registered in Kubernetes..."
for i in {1..10}; do
    if kubectl get job vlan-ip-initializer -n kube-system &>/dev/null; then
        echo "Initializer Job found."
        break
    fi
    echo "Job not found yet. Retrying in 5 seconds... ($i/10)"
    sleep 5
done

# Wait for Job to complete
echo "Waiting for Initializer Job to complete..."
kubectl wait --for=condition=complete --timeout=600s job/vlan-ip-initializer -n kube-system

# === Step 6: Deploy Leader Manager Deployment ===
echo "Deploying VLAN Leader Manager..."
Apply_etcd_endpoint_vlan_ip_controller_deployment

# Wait for deployment to be ready
echo "Waiting for VLAN Leader Manager to be ready..."
kubectl rollout status deployment/vlan-ip-controller -n kube-system

# === Check if port 8080 is open and healthy ===
echo "Checking if port 8080 is available on vlan-ip-controller..."
# NOTE: LEADER_POD is re-selected on every retry, filtered to Running pods
# only. A single selection made once, before this loop, with no Running
# filter, is a real bug found live: `kubectl apply` just above this can
# trigger a rolling update, and jsonpath='{.items[0]...}' has no ordering
# guarantee that excludes an old ReplicaSet's pod that's already
# Terminating. If that's the one picked, every one of the 10 retries below
# targets that same dying pod and fails, even though `kubectl rollout
# status` (which already ran, above) confirmed the NEW replicas are
# healthy - and this whole script `exit 1`s on that false failure, which
# used to (via the EXIT trap at the top of this file) tear down the
# ENTIRE deployment, not just this one check, regardless of whether it was
# a fresh deploy or a re-run against an already-working cluster. Confirmed
# live: the failed pod's own logs showed `/health` returning 200
# continuously right up until it received SIGTERM - it was never actually
# unhealthy. See is_fresh_deploy()/cleanup_on_unexpected_failure() near
# the top of this file for the fix to the blast-radius half of this; this
# fix is to the false-failure trigger itself.
for i in {1..10}; do
    LEADER_POD=$(kubectl get pods -n kube-system -l app=vlan-ip-controller --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
    if [[ -n "$LEADER_POD" ]] && kubectl exec -n kube-system "$LEADER_POD" -- curl -s http://localhost:8080/health &> /dev/null; then
        echo "VLAN Leader Manager is healthy and responding."
        break
    else
        echo "Waiting for VLAN Leader Manager to become healthy... ($i/10)"
        sleep 6
    fi
done

if [ $i -eq 10 ]; then
    echo "VLAN Leader Manager failed to become healthy. Capturing logs..."
    kubectl logs -n kube-system $LEADER_POD > vlan-ip-controller-logs.txt
    echo "Logs saved to vlan-ip-controller-logs.txt"
    exit 1
fi

# === Step 7: Install Kyverno + Apply VLAN-ready Policy ===
ENABLE_KYVERNO="$(get_cm_value ENABLE_KYVERNO | tr '[:upper:]' '[:lower:]')"
if [[ "${ENABLE_KYVERNO}" == "true" ]]; then
echo "Installing Kyverno and applying VLAN-ready policy..."
install_kyverno || { log "Kyverno install failed"; exit 1; }
apply_kyverno_policy || { log "Kyverno policy apply failed"; exit 1; }
else
log "Kyverno disabled → skipping"
fi

# === Step 8: Deploy vlan-config-controller Deployment ===
echo "Deploying vlan-config-controller Deployment..."
apply_vlan_config_controller

# === Step 9: Deploy VLAN Manager DaemonSet ===
echo "Deploying VLAN Manager DaemonSet..."
Create_vlan_manager_daemonset

# Wait for DaemonSet rollout
echo "Waiting for VLAN Manager DaemonSet to be ready..."
kubectl rollout status daemonset/vlan-manager -n kube-system

# === Log command hints for DaemonSet Pods ===
echo "Fetching VLAN Manager Pods..."
PODS=$(kubectl get pods -n kube-system -l app=vlan-manager -o jsonpath='{.items[*].metadata.name}')

if [ -z "$PODS" ]; then
    echo "No VLAN Manager pods found. Exiting..."
    exit 1
fi

echo "VLAN Manager DaemonSet is fully deployed."
echo "You can monitor the logs using the following commands:"
for pod in $PODS; do
    echo "kubectl logs -f pod/$pod -n kube-system"
done

echo "VLAN Leader Manager is up and running."

# === Step 10: Deploy VLAN IP Reconciler CronJob (optional) ===
ENABLE_IP_RECONCILER="$(get_cm_value ENABLE_IP_RECONCILER | tr '[:upper:]' '[:lower:]')"
if [[ "${ENABLE_IP_RECONCILER}" == "true" ]]; then
    echo "Deploying VLAN IP Reconciler CronJob..."
    # NOTE: every other envsubst '${ETCD_ENDPOINTS}' call in this script is
    # wrapped in its own function that exports ETCD_ENDPOINTS right before
    # use and unsets it right after (see e.g. apply_vlan_config_controller()).
    # This step used to be a bare block with no such export of its own - it
    # silently relied on whichever earlier step happened to run last having
    # left ETCD_ENDPOINTS set, which nothing does (every one of them unsets
    # it when done). The result: envsubst substituted an EMPTY value, the
    # deployed CronJob's ETCD_ENDPOINTS env var ended up with no value at
    # all, and every run (scheduled or manual, `kubectl create job
    # --from=cronjob/vlan-ip-reconciler ...` included) failed immediately
    # with "ETCD_ENDPOINTS: ETCD_ENDPOINTS not set" - confirmed live against
    # a real cluster, both on its own 15-minute schedule and via the manual
    # command README.md itself documents. The reconciler never actually ran
    # successfully once, on any deployment, until this fix.
    NODE_COUNT=$(get_worker_node_count)
    log "Detected $NODE_COUNT worker node(s) in the cluster."
    if [ "$NODE_COUNT" -lt 3 ]; then
        export ETCD_ENDPOINTS="http://etcd-0.etcd.kube-system.svc.cluster.local:2379"
    else
        export ETCD_ENDPOINTS="http://etcd-0.etcd.kube-system.svc.cluster.local:2379,http://etcd-1.etcd.kube-system.svc.cluster.local:2379,http://etcd-2.etcd.kube-system.svc.cluster.local:2379"
    fi
    envsubst '${ETCD_ENDPOINTS}' < 11-vlan-ip-reconciler-cronjob.yaml | kubectl apply -f - || {
        log "VLAN IP Reconciler CronJob deployment failed"
        unset ETCD_ENDPOINTS
        exit 1
    }
    unset ETCD_ENDPOINTS
    echo "VLAN IP Reconciler CronJob deployed - runs every 15 minutes, see docs/DEPLOYMENT.md for details."
else
    echo "ENABLE_IP_RECONCILER=false → skipping VLAN IP Reconciler CronJob."
fi

echo "Orchestration Complete! VLAN Manager is fully operational."
DEPLOYMENT_SUCCESS="true"
exit 0

# NOTE: unreachable - `exit 0` above already ends the script, every time,
# on every successful run. Pre-existing dead code (not introduced by any
# of the fixes in this file); left as-is rather than silently deleted -
# flagging it here rather than assuming it's safe to remove without
# checking whether it was ever meant to be reachable from some other path.
trap cleanup_on_unexpected_failure INT TERM
