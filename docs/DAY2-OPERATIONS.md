# Day 2 Operations: Linode LKE VLAN Orchestration

This document covers operational procedures you'll need on a cluster that's
**already deployed and running** this automation — as opposed to
[docs/DEPLOYMENT.md](DEPLOYMENT.md), which covers initial install and
configuration recipes, or [docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md), which
covers diagnosing things that are actively broken.

Think of this as the runbook for routine (but still sensitive, still-prod)
operational tasks: replacing/removing specific nodes, and anything else that
comes up as this repo's automation runs on live clusters over time.

---

## Table of contents

- [Removing a specific node from a live cluster](#removing-a-specific-node-from-a-live-cluster)
- [Updating configuration after deployment](#updating-configuration-after-deployment)
- [Migration: Retiring `infra-pool`](#migration-retiring-infra-pool)
- [Uninstallation](#uninstallation)
- [Recovering a stuck `vlan-config-controller`](#recovering-a-stuck-vlan-config-controller)

---

## Removing a specific node from a live cluster

### When to use this

Use this when you need to permanently remove **one or two specific nodes**
from a cluster — for example, a node has an external IP conflict with
something outside this cluster, failing hardware, or any other reason you've
already diagnosed and decided the node itself needs to go (as opposed to a
routine autoscaler scale-down, which Kubernetes/Linode already handle on
their own).

**This is not the same as node pool autoscaling or `post-migration-consolidate.sh`.**
Those are covered in DEPLOYMENT.md. This procedure is for a targeted,
manual removal of specific node(s) you've already identified by name.

### Why you can't just `kubectl delete node`

For LKE, `kubectl delete node <name>` only removes the Kubernetes API
object — it does **not** terminate the underlying Linode instance, and does
not remove it from the LKE node pool. The instance keeps running, LKE will
typically just re-register it (or the autoscaler will replace it), and
whatever problem prompted the removal will still be there. Actual removal
has to go through the LKE API (`linode-cli lke node-delete`), which properly
terminates the instance and removes it from the pool.

### Before you start: check what's running on the node

Critical infrastructure pods (`etcd`, `vlan-config-controller`, CoreDNS)
aren't necessarily pinned to a dedicated pool — on clusters already migrated
to the `post-migration/` manifest variant (see DEPLOYMENT.md), they can land
on *any* regular node via the `vlan-ready=true` node affinity. **Always check
first** rather than assuming:

```bash
kubectl get pods -A -o wide | grep -E "<node-name-1>|<node-name-2>"
```

If an `etcd-N` pod is on one of the nodes you're removing, that's fine to
proceed with (etcd's `PodDisruptionBudget` requires `minAvailable: 2`, so
losing one of three is tolerated), but it means that node needs the extra
etcd-health check in step 3 below, and — if removing two nodes — you should
**drain them one at a time**, not simultaneously, so you can catch a problem
with the etcd node early rather than compounding it with app-pod disruption
on both nodes at once.

### Step 1: Cordon (stop new scheduling, no disruption yet)

```bash
kubectl cordon <node-name-1>
kubectl cordon <node-name-2>
```

### Step 2: Drain nodes with no critical infra pods first

```bash
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
```

`--ignore-daemonsets` is required — `vlan-manager`, `cilium`,
`csi-linode-node`, and `k8s-proxy` are DaemonSet-managed and are expected to
stay/be recreated; drain will warn about skipping them, that's normal.

Confirm everything else rescheduled cleanly elsewhere before moving to the
next node:

```bash
kubectl get pods -A -o wide | grep -v Running | grep -v Completed
```

(Any `CrashLoopBackOff` pods showing up here that are **not** on the node(s)
you just drained are pre-existing and unrelated — don't assume the drain
caused them; cross-check the node column.)

### Step 3: Drain the node hosting etcd (if any) last, and verify etcd health

```bash
kubectl drain <etcd-node-name> --ignore-daemonsets --delete-emptydir-data
```

Then confirm etcd rescheduled and is actually healthy — not just `Running`,
but check its logs for a clean leader election with no repeating errors:

```bash
kubectl get pods -n kube-system -l app=etcd -o wide
kubectl logs -n kube-system etcd-<N> --tail=20
```

You want to see all etcd pods `Running`, the evicted one now on a
**different** node than before, and log lines like `elected leader` /
`ready to serve client requests` with no connection-refused spam.

### Step 4: Find the LKE node ID for each node you're removing

The LKE API identifies nodes by an `id` field that (for LKE) is the same
string as the Kubernetes node name — but it's a distinct concept from the
Linode **instance ID**, and `lke node-delete` requires the former, not the
latter. Confirm both together to avoid mixing them up:

```bash
linode-cli lke pools-list <LKE_CLUSTER_ID> --json \
  | jq '.[].nodes[] | select(.instance_id==<instance_id_1> or .instance_id==<instance_id_2>)'
```

(Get each node's `instance_id` via
`kubectl get node <name> -o jsonpath='{.spec.providerID}'`, which returns
`linode://<instance_id>`.) `LKE_CLUSTER_ID` is the same value as
`LKE_CLUSTER_ID` in `manifests/00-vlan-manager-configmap.yaml` for that
cluster.

### Step 5: Delete the nodes via the LKE API

```bash
linode-cli lke node-delete <LKE_CLUSTER_ID> <node-name-1>
linode-cli lke node-delete <LKE_CLUSTER_ID> <node-name-2>
```

This terminates the underlying Linode instance and removes it from the pool.

### Step 6: Confirm clean removal

```bash
kubectl get nodes | grep -E "<node-name-1>|<node-name-2>"
linode-cli lke pools-list <LKE_CLUSTER_ID> --json \
  | jq '.[].nodes[] | select(.instance_id==<instance_id_1> or .instance_id==<instance_id_2>)'
```

Both should return nothing. If a Kubernetes Node object lingers (kubelet
occasionally doesn't deregister cleanly before the instance disappears),
clear it manually:

```bash
kubectl delete node <name>
```

### Step 7: Follow-up checks

- **Autoscaler replacements**: if the pool has a minimum size that requires
  replacement capacity, new nodes will spin up automatically and go through
  the normal onboarding flow (VLAN attach, `vlan-ready=true` labeling, etc.)
  like any other new node — no special handling needed, but worth confirming
  node count matches expectations:
  ```bash
  linode-cli lke pools-list <LKE_CLUSTER_ID> --json \
    | jq '.[] | {id, autoscaler, count: (.nodes | length)}'
  ```
- **Orphaned VLAN IPs**: the removed nodes' VLAN IP allocations become
  orphans in etcd. `vlan-ip-reconciler` (if enabled — see
  [DEPLOYMENT.md#vlan-ip-pool-reconciliation](DEPLOYMENT.md#vlan-ip-pool-reconciliation))
  detects and releases these automatically after confirming twice, 15
  minutes apart. No manual action needed, but you can spot-check the next
  scheduled run's logs if you want confirmation rather than waiting.

---

## Updating configuration after deployment

Once the automation is up and running, you'll periodically need to change a setting — add a route, turn on a firewall feature, rotate a token. This section covers how to do that safely on a live cluster, and which settings behave differently from the rest.

### The general mechanism

Every setting in `vlan-manager-config` and `vlan-manager-secrets` reaches the running containers as an **environment variable**, sourced via `configMapKeyRef`/`secretKeyRef`. Environment variables are only read once, when a container starts — `kubectl apply`-ing an updated ConfigMap or Secret changes the stored object, but it does **not** reach pods that are already running. The second step is always a rollout restart of whichever workload consumes that setting, so its pods restart and re-read the new values:

```bash
kubectl apply -f 00-vlan-manager-configmap.yaml
kubectl rollout restart daemonset/vlan-manager -n kube-system
kubectl rollout status daemonset/vlan-manager -n kube-system
```

For nodes that already have their VLAN interface attached (which is every node in a running cluster), this restart does **not** trigger a reboot. `scripts/02-script-vlan-attach.sh` re-checks VLAN/VPC state fresh on every pod start; once it sees the interface is already present, it takes the no-reboot path that just re-applies routes, firewall, and `iptables` rules and goes back to sleep. `push_route` and `configure_vlan_ew_firewall` both check for the existing state (`ip route show`, `iptables -C`) before adding anything, so re-running them is safe — nothing gets duplicated.

### Which keys behave differently

Not every setting follows the simple "apply + rollout restart" pattern. Before changing something, check which category it falls into:

| Behavior | Keys | What actually happens |
|---|---|---|
| **Hot-reload via rollout restart, no reboot** | `ROUTE_LIST`, `ENABLE_PUSH_ROUTE`, `ENABLE_VLAN_EW_FIREWALL`, `ENABLE_FIREWALL` (Standard only) | Picked up by every `vlan-manager` pod on restart; applied in place since the node's VLAN is already attached. See the two recipes below. |
| **Triggers a real reboot automatically** | `ENABLE_VPC_INTERFACE` (`false` → `true` on an existing cluster) | The restarted pod detects VLAN-present-but-VPC-missing and follows the same allocate → config-update → reboot path a brand-new node would. Expect a real reboot on every node the next time you restart the DaemonSet with this flipped on. |
| **Only affects newly onboarded nodes** | `SUBNET`, `VLAN_LABEL`, `REGION`, `LKE_CLUSTER_ID`, `LKE_CLUSTER_TYPE` | Nodes that already have a VLAN interface skip the allocation logic entirely regardless of what these say now — changing them doesn't retroactively touch already-attached nodes, only ones that onboard after the change (new nodes, autoscaler-added nodes). Changing `LKE_CLUSTER_TYPE`/`REGION`/`LKE_CLUSTER_ID` on a live cluster generally isn't meaningful — these describe the cluster itself, not something you'd expect to change. |
| **Requires Secret delete/recreate (immutable)** | `LINODE_API_KEY`, `LINODE_CLI_CONFIG` | See [Secrets vs ConfigMap](DEPLOYMENT.md#secrets-vs-configmap) — the Secret template sets `immutable: true`, so it can't be patched in place. |

### Recipe: adding or changing static routes

```bash
cd manifests
# edit 00-vlan-manager-configmap.yaml, add/change entries under ROUTE_LIST:
#   ROUTE_LIST: |
#     - route_ip: "10.80.0.254"
#       dest_subnet: "10.2.0.0/16"
#     - route_ip: "10.80.0.254"
#       dest_subnet: "10.9.0.0/16"   # <- new entry

kubectl apply -f 00-vlan-manager-configmap.yaml
kubectl rollout restart daemonset/vlan-manager -n kube-system
kubectl rollout status daemonset/vlan-manager -n kube-system
```
Verify on any node:
```bash
kubectl exec -n kube-system <vlan-manager-pod> -- ip route show | grep <new-dest-subnet>
```
Removing a route from `ROUTE_LIST` does not remove it from nodes that already have it — `push_route` only ever adds. Remove a stale route by hand with `ip route delete` on affected nodes, or via a reboot.

### Recipe: enabling the VLAN east-west firewall

```bash
cd manifests
# edit 00-vlan-manager-configmap.yaml:
#   ENABLE_VLAN_EW_FIREWALL: "true"

kubectl apply -f 00-vlan-manager-configmap.yaml
kubectl rollout restart daemonset/vlan-manager -n kube-system
kubectl rollout status daemonset/vlan-manager -n kube-system
```
Verify:
```bash
kubectl exec -n kube-system <vlan-manager-pod> -- iptables -L INPUT -v -n
```
This is one-directional: `configure_vlan_ew_firewall` only ever adds the two rules when the flag is `true`. Flipping it back to `"false"` later and restarting does **not** remove the rules already applied — they stay until the node reboots or you remove them by hand (`iptables -D INPUT ...`). Don't rely on this flag alone to toggle the feature off on a live node.

### Applying the vlan-not-ready taint

App-pod scheduling is gated by two layers together, not the taint alone:

1. A `vlan-not-ready=true:NoSchedule` node taint, set at the app pool's node-pool config and **permanent — deliberately never removed**. Earlier iterations of this design tried clearing it per-node once VLAN attach completed (mirroring how `infra-pool`'s taint is managed), but LKE treats pool-level taints as ongoing desired state and reconciles them back onto every node in the pool indefinitely — including nodes that already finished VLAN attach and had the taint legitimately cleared, confirmed empirically on a live test cluster. Fighting that reconciliation is a losing battle, so this design stopped trying: the taint just permanently means "you must be a workload that knows about this pool," a static membership check.
2. The `vlan-ready=true` node **label**, set once by `mark_node_vlan_ready()` in `scripts/02-script-vlan-attach.sh` when VLAN attach, routes, and firewall rules are all confirmed, and never touched by anything external (not LKE, not any other automation). This is the real, dynamic "is this specific node ready" signal.

A Kyverno policy (`linode-lke-vlan-gating`, installed automatically by `00-Orchestration-Script.sh` when `ENABLE_KYVERNO=true`) ties the two together: it mutates every application Pod to add `nodeSelector: vlan-ready: "true"` (requiring layer 2) and a toleration for the permanent taint (granting passage through layer 1) — with zero changes required to the Pod's own spec. `apply_kyverno_policy()` picks the policy TYPE automatically: a CEL-based `MutatingPolicy` (`manifests/09-kyverno-vlan-ready-mutatingpolicy.yaml`, `policies.kyverno.io/v1`) on any cluster whose Kyverno ships that CRD, or the legacy JMESPath `ClusterPolicy` (`manifests/09-kyverno-vlan-ready-policy.yaml`, `kyverno.io/v1`) as a fallback on an older Kyverno install — the legacy type is deprecated as of Kyverno v1.19 and scheduled for removal in v1.20 (~October 2026), so a fresh deploy on any reasonably current cluster gets the `MutatingPolicy`. This is actually the *third* generation of Kyverno's role here. The very first version mutated a required `nodeAffinity` onto every Pod directly (no taint involved at all) and broke the moment a second, independently-installed project's Kyverno policy reached for the same shared `nodeAffinity`/`nodeSelectorTerms` field — whichever policy Kyverno evaluated last silently overwrote the other's patch, with no reliable way to guarantee evaluation order. The second (and current-default) generation avoids that specific collision by injecting into a flat `nodeSelector` map instead (independent keys merge for free, no shared-list collision is possible) and by appending to the toleration list (JSON Patch in both policy types) rather than a full-list strategic-merge replace. See each policy file's header comment for the complete history.

The taint still matters even with Kyverno doing the real gating — it's defense-in-depth. If Kyverno's webhook is ever unreachable when a pod is created (restart, upgrade, or any other transient gap), that pod gets created with no mutation at all; without the taint, nothing would stop it from landing on a node that hasn't finished VLAN attach. With the taint present, that same unprotected pod just can't schedule anywhere in the pool — it sits `Pending` visibly instead of running somewhere broken.

**The taint only works as intended if it's set at the node pool level** — via Cloud Manager, `linode-cli`, or Terraform, at pool creation or through a pool-config update — not applied reactively with `kubectl taint` after nodes already exist. A pool-level taint is inherited automatically by every node the pool ever creates, including ones added later by manual scale-up, pool recycle, or cluster-autoscaler; a `kubectl`-applied one only covers the nodes that existed at the moment you ran the command, and won't survive a node being replaced. `infra-pool`'s own taint has historically been applied the `kubectl taint` way (see `DEDICATED-NODEPOOL.md`, now deprecated) — that's a real, separate durability gap worth closing the same way, not something to copy here.

**1. Set the taint on the app pool's config.** On a cluster already running this project's `00-Orchestration-Script.sh`, this is normally automatic — `ensure_app_pool_taint()` finds the app-pool via its `app-pool=true` label on every deploy and keeps `vlan-not-ready` present, merging with (never replacing) any other project's taint already there. The manual sequence below is only needed to retrofit the `app-pool=true` label onto a pool that predates this convention, or if you're managing pools entirely outside this project's tooling:
```bash
# linode-cli, on an existing pool:
linode-cli lke pools-list <cluster-id> --json | jq '.[] | {id, type, count, taints, labels}'   # find the app pool's id, check current taints/labels
linode-cli lke pool-update <cluster-id> <pool-id> \
  --labels '{"app-pool":"true"}' \
  --taints.key vlan-not-ready --taints.value true --taints.effect NoSchedule
  # add --taints.key/.value/.effect again for each other taint already
  # present (e.g. a sibling project's own) in this same call
```
(No `.0.` index — `linode-cli lke pool-update --help` confirms the flat `--taints.key`/`--taints.value`/`--taints.effect` form; an indexed form fails with `unrecognized arguments`. Also note: a second `pool-update` call with a *different* `--taints.*` value **replaces** the pool's taints array rather than appending to it — if a pool ever needs more than one taint, set them together in the same call, or you'll silently wipe out the first one. `ensure_app_pool_taint()` handles this correctly on every automated run once the `app-pool=true` label is in place; this note is for the manual/retrofit path only.)

Or the equivalent field in Terraform (`linode_lke_cluster` pool block) or Cloud Manager's node pool taint UI — just make sure the `app-pool=true` label lands too, or `ensure_app_pool_taint()` won't be able to find this pool automatically. Avoid a `kubernetes.io`/`linode.com`-prefixed key — those domains are reserved for LKE's own use; a bare key like `vlan-not-ready` is safe.

**2. Confirm Kyverno and its policy are installed** — normally automatic via `00-Orchestration-Script.sh` when `ENABLE_KYVERNO=true` in the ConfigMap, but if you're retrofitting this onto a cluster that predates it:
```bash
kubectl get crd clusterpolicies.kyverno.io &>/dev/null || \
  kubectl create -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml --validate=false
kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=300s
cd manifests
# Pick the policy type this cluster's Kyverno actually supports - never
# apply both (see apply_kyverno_policy() in 00-Orchestration-Script.sh for
# the same dispatch logic, automated):
if kubectl get crd mutatingpolicies.policies.kyverno.io &>/dev/null; then
  kubectl delete clusterpolicy linode-lke-vlan-gating --ignore-not-found
  kubectl apply -f 09-kyverno-vlan-ready-mutatingpolicy.yaml
  kubectl get mutatingpolicy linode-lke-vlan-gating
else
  kubectl delete mutatingpolicy linode-lke-vlan-gating --ignore-not-found
  kubectl apply -f 09-kyverno-vlan-ready-policy.yaml
  kubectl get clusterpolicy linode-lke-vlan-gating
fi
```
If Kyverno's own pods sit `Pending`, it's almost certainly because both node pools now carry custom taints and Kyverno's upstream manifest has no tolerations of its own — see `install_kyverno()` in `00-Orchestration-Script.sh` for the post-install patch that pins it to `infra-pool`, and apply the same patch manually if you installed Kyverno outside the script.

**Sharing Kyverno with a sibling project (e.g. `lke-e-acl-operator`):** `install_kyverno()` is safe to run regardless of deploy order. If Kyverno is already installed (by this script or another project's), it skips the install manifest but still always re-checks and re-applies the infra-pool pinning — using an additive JSON Patch for tolerations, never a blind replace — so it can't wipe out a toleration a sibling project's own install already added, and it closes the gap where Kyverno's pods would otherwise end up with zero pinning if some other project installed Kyverno first without pinning it anywhere itself.

**3. Deploy (or update) `vlan-manager`** — its DaemonSet already tolerates any taint on the app-pool, with an explicit `nodeAffinity` requiring the `app-pool=true` label instead (`manifests/07-vlan-manager-daemonset.yaml` — see [Coexisting with other Kyverno-gated projects](DEPLOYMENT.md#coexisting-with-other-kyverno-gated-projects) for why), so it can still land on a node to do its job regardless of the taint, while staying off `infra-pool` and any other unlabeled pool on the cluster:
```bash
cd manifests
kubectl apply -f 07-vlan-manager-daemonset.yaml
kubectl rollout status daemonset/vlan-manager -n kube-system
```

**4. Verify** — check the dynamic signal (label), not the taint (which is present on every app-pool node by design now, so its presence alone tells you nothing):
```bash
# Every app-pool node should eventually show vlan-ready=true once its VLAN
# attach completes.
kubectl get nodes -L vlan-ready -o json | jq -r '.items[] | "\(.metadata.name)\t\(.metadata.labels."vlan-ready")"'

# Confirm vlan-manager itself is actually running, not stuck Pending.
kubectl get pods -n kube-system -l app=vlan-manager -o wide

# Confirm Kyverno is really mutating pods - deploy anything with zero
# special config and check what it ended up with:
kubectl run verify-vlan-gating --image=nginx -n default
kubectl get pod verify-vlan-gating -o yaml | grep -A6 tolerations
kubectl delete pod verify-vlan-gating -n default
```

**Testing before a live rollout:** validate this whole sequence on a non-production cluster first — confirm a *brand-new* node (not just existing ones) actually comes up tainted, since that's the specific race the pool-level taint exists to close. Existing nodes already having the taint doesn't prove pool-level durability; a freshly-provisioned or autoscaler-added node showing it does.

### Recipe: rotating the Linode API token

```bash
kubectl delete secret vlan-manager-secrets -n kube-system
kubectl create secret generic vlan-manager-secrets -n kube-system \
  --from-literal=LINODE_API_KEY='<new-token>' \
  --from-file=LINODE_CLI_CONFIG=<path-to-updated-linode-cli-ini-file>
kubectl rollout restart daemonset/vlan-manager deployment/vlan-config-controller deployment/vlan-ip-controller -n kube-system
```
Do this during a low-risk window — deleting the Secret briefly removes it before the new one is created, and any pod that happens to restart in that gap (crash, eviction) will fail to start until the new Secret exists.

### Recipe: changing etcd, `vlan-config-controller`, or any other `ETCD_ENDPOINTS`-templated manifest

Several manifests — `08-etcd-StatefulSet-3node.yaml` (or `-1node.yaml`), `10-vlan-config-controller.yaml`, `05-vlan-ip-initializer-job.yaml`, `06-vlan-ip-controller-deployment.yaml`, `07-vlan-manager-daemonset.yaml` — contain a literal `${ETCD_ENDPOINTS}` placeholder rather than a real value. `00-Orchestration-Script.sh` substitutes it via `envsubst` on first deploy. If you need to change and reapply one of these later (a ConfigMap-driven env var, an image bump, anything), **you must repeat that substitution by hand** — `kubectl apply -f <file>.yaml` on its own applies the literal string `${ETCD_ENDPOINTS}` as the env var's value, and the pod fails with `curl: (3) URL rejected: Bad hostname` trying to use it, while still reporting `1/1 Ready` (the readiness probe doesn't check etcd connectivity) and the rollout still reporting `successfully rolled out`. This is easy to miss — a clean-looking rollout can still be a completely non-functional pod.

Two checks, in order, before touching anything:

**1. Confirm which manifest variant this cluster is actually running right now** — the original `infra-pool`-nodeSelector version, or the `post-migration/` `vlan-ready`-nodeAffinity version (from having already run `post-migration-consolidate.sh`). Applying the wrong one makes the pod unschedulable — if the cluster has already retired `infra-pool`, the original manifest's `nodeSelector: infra-pool: "true"` will never match any node at all.
```bash
kubectl get nodes -l infra-pool=true
kubectl get deployment vlan-config-controller -n kube-system -o yaml | grep -A 15 "affinity:\|nodeSelector:"
```
If `infra-pool` nodes exist and the live spec shows `nodeSelector: infra-pool: "true"` → use the file from `manifests/`. If `infra-pool=true` returns nothing and the live spec shows `nodeAffinity` on `vlan-ready=true` → use the matching file from `manifests/post-migration/` instead.

**2. Set `ETCD_ENDPOINTS` to match this cluster's actual etcd replica count:**
```bash
kubectl get pods -n kube-system -l app=etcd
```
```bash
# 1 replica:
export ETCD_ENDPOINTS="http://etcd-0.etcd.kube-system.svc.cluster.local:2379"

# 3 replicas:
export ETCD_ENDPOINTS="http://etcd-0.etcd.kube-system.svc.cluster.local:2379,http://etcd-1.etcd.kube-system.svc.cluster.local:2379,http://etcd-2.etcd.kube-system.svc.cluster.local:2379"
```

Then apply through `envsubst`, never directly:
```bash
cd manifests   # or manifests/post-migration, per step 1
envsubst '${ETCD_ENDPOINTS}' < <the-manifest-file>.yaml | kubectl apply -f -
unset ETCD_ENDPOINTS

kubectl rollout status <deployment-or-statefulset-kind>/<name> -n kube-system
```

**Verify it's actually functioning, not just that the rollout succeeded:**
```bash
kubectl -n kube-system exec deploy/vlan-config-controller -- env | grep ETCD_ENDPOINTS
kubectl logs -n kube-system deploy/vlan-config-controller --tail=15
```
A real `http://etcd-N...` value (not the literal string `${ETCD_ENDPOINTS}`) and the absence of a repeating `No healthy etcd endpoint reachable` log line confirm it worked.

---

## Migration: Retiring `infra-pool`

**This section has moved to [docs/DEPLOYMENT.md#migration-retiring-infra-pool](DEPLOYMENT.md#migration-retiring-infra-pool).** It's a one-time step performed right after a successful deployment converges (not an ongoing Day 2 operation), so it now lives in the deployment guide alongside Installation and Verification. Covers the cutover script (`post-migration-consolidate.sh`), the final cross-check before deleting the pool, the pool-deletion sequence itself, and rollback.

---

## Uninstallation

To completely remove the deployment, run the following from inside `manifests/`:
```bash
./00-Orchestration-Script.sh --cleanup
```

This does not remove the `infra-pool` node pool itself or its label/taint — remove that separately via Cloud Manager / `linode-cli` if you're tearing the whole thing down.

---

## Recovering a stuck `vlan-config-controller`

Use this when the controller is stuck (e.g. "Leader lock held by another replica" in a loop, or nodes are offline but the controller is not updating their config).

### Why it gets stuck

- **Leader lock**: Only one controller pod holds the leader key at a time. If that pod is stuck inside `process_job` (e.g. waiting for a node to go offline, or `linode-cli` hanging), other replicas keep seeing "Leader lock held by another replica."
- **Reboot lock**: The controller processes **only the job for the node that holds `/coredns-reboot-lock`** first. The controller **never** deletes the reboot lock when it marks a job as failed (e.g. "running but config mismatch"); it only deletes the lock after successfully completing a job (config update + boot). That preserves serialized shutdown: only one node can hold the lock at a time, and the next node can acquire only after the controller has finished the current one. If the controller used to delete the lock on failure, multiple nodes could shut down in parallel and leave nodes stuck offline.
- **Pod on the rebooting node**: With 2 replicas, one controller pod can be scheduled on the **same node** that holds the reboot lock and is shutting down. When that node goes offline, that pod becomes unreachable: `kubectl logs` to it will timeout (e.g. `dial tcp 10.0.0.x:10250: i/o timeout`) because the kubelet on that node is down. The pod may still show "Running" until the control plane marks the node NotReady and evicts it. Use **replicas: 1** during migration so the single pod is less likely to be on the node being updated, or check logs on the **other** pod.
- **Pod shows Running but logs timeout (node Ready, kubelet unreachable)**: Sometimes a node stays **Ready** but its kubelet stops responding (e.g. network issue, kubelet stuck). `kubectl logs` then times out (`dial tcp 10.x.x.x:10250: i/o timeout`). The pod is not actually running; the control plane just hasn't evicted it yet. **Fix:** delete the controller pod so the Deployment recreates it and the scheduler places it on another node: `kubectl delete pod -l app=vlan-config-controller -n kube-system`. Then check logs on the new pod. **Automation:** the watchdog CronJob is in `10-vlan-config-controller.yaml` (same file as the controller). When you apply that file, the CronJob is created too; it runs every 2 minutes, execs into the controller pod with a short timeout, and deletes the pod if unreachable so it gets rescheduled.
- **Other pod restarts (CrashLoopBackOff)**: Transient failures (Linode API timeouts, empty responses, curl/jq errors) used to exit the controller script and restart the container. The script is now hardened with `set +e` in the main loop so it keeps running; ensure you run the latest `07-vlan-config-controller-scripts.sh`.

### How the leader lock and auto-recovery work (normal behavior)

The controller uses a **leader lock** in etcd (`/vlan-config-controller/leader`) so only one pod processes jobs at a time. After it finishes processing job(s) in a loop, it **releases** the lock (deletes the key) and sleeps a few seconds, then tries to **acquire** again for the next loop.

**Why you sometimes see "Leader lock held by another replica" for a while**

After completing a job, the pod releases the lock. On the next loop it tries to acquire. Sometimes the key is still there (e.g. the delete failed briefly, or there was a race), so the pod logs "Leader lock held by another replica" and retries every 3 seconds. This is **expected**; the controller does not require manual action in this case.

**How it recovers on its own (auto-recovery)**

The script has two built-in recovery mechanisms:

1. **Stale key:** When the key exists but its timestamp is older than **45 seconds** (`LEADER_STALE_SEC`), the pod that fails to acquire **deletes** the key and retries. On the next loop it can acquire and continue processing.

2. **Force-delete after repeated failures:** After **25 consecutive** failed acquire attempts (~75 seconds of "Leader lock held…"), the script **force-deletes** the leader key once, then continues. On the next loop it can acquire.

So the controller may appear **stuck** for about **45–75 seconds** after completing a job, then **resume** and process pending jobs (you may see "No reboot lock; processing all N pending job(s)" and then each job completed in turn). No manual intervention is needed unless it stays stuck for much longer (then use the steps in **1. Unstick the leader lock** below).

**Log messages you may see**

- `Leader lock held by another replica. Retrying in 3s...` — normal while waiting to re-acquire.
- `Leader key stale (ts=…, now=…). Deleting so another replica can acquire.` — stale-key recovery.
- `Force-deleting leader key after … consecutive failures (recovery).` — force-delete recovery.
- After recovery: `[JOBS] Found N job(s)…` and jobs being processed.

### 1. Unstick the leader lock

The controller will **auto-recover** in two ways: (1) if the leader key's timestamp is older than 45s it is treated as stale and deleted; (2) after ~75 seconds of consecutive "Leader lock held by another replica", the key is force-deleted once. So with **replicas: 1**, waiting 1–2 minutes may be enough. If you need an **immediate** fix:

**Option A – Scale to one replica**
Ensure only one replica so a single pod can take over after staleness/force-delete:

```bash
kubectl scale deployment vlan-config-controller -n kube-system --replicas=1
# Wait ~1–2 minutes for auto-recovery, or use Option B for immediate fix
kubectl logs -f deployment/vlan-config-controller -n kube-system
```

**Option B – Delete the leader key in etcd (immediate)**
Any replica can then acquire on the next loop.

```bash
kubectl exec -n kube-system etcd-0 -- env ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 del /vlan-config-controller/leader
```

### 2. DaemonSet pods can't reach etcd ("etcd unreachable from all endpoints")

**Controller seeing "All endpoints failed" while etcd pods are Running:**
etcd and CoreDNS can be Running but the controller may still log `[etcd] All endpoints failed`. Causes: DNS (controller may not resolve `etcd-0.etcd.kube-system.svc.cluster.local`), network (flaky connectivity to etcd Service), or timeout (script uses 10s). If you also see `Leader lock held by another replica`, etcd is reachable in some loops (intermittent). With replicas=1, after ~45s the leader key becomes stale and the single pod will acquire. **Check from controller pod:**
`kubectl exec -n kube-system CONTROLLER_POD -- sh -c 'for ep in $(echo "$ETCD_ENDPOINTS" | tr "," " "); do echo "Trying $ep"; curl -s --max-time 10 -X POST "$ep/v3/kv/range" -H "Content-Type: application/json" -d "{\"key\":\"Lw\"}" | head -c 200; echo; done'`
If every endpoint times out, fix DNS/network or reschedule: `kubectl delete pod -l app=vlan-config-controller -n kube-system`.

If the DaemonSet on some nodes never sees the lock as released, it may be because **those pods cannot reach etcd** (e.g. after a node came back, network or DNS differs). You'll see either:

- **"etcd unreachable at … (empty or invalid response). Trying next endpoint..."** then **"etcd unreachable from all endpoints..."** (script now tries each `ETCD_ENDPOINTS` and logs this),
- or older script: **"Lock held by unknown"** in a loop (empty etcd response was treated as "lock held").

**Check connectivity from a stuck node:**

```bash
# From your machine: run inside a vlan-manager pod on a stuck node (replace POD_NAME)
kubectl exec -it -n kube-system POD_NAME -- sh -c 'echo "ETCD_ENDPOINTS=$ETCD_ENDPOINTS"; for ep in $(echo "$ETCD_ENDPOINTS" | tr "," " "); do echo "Trying $ep ..."; curl -s --max-time 5 -X POST "$ep/v3/kv/range" -H "Content-Type: application/json" -d "{\"key\":\"L2NvcmVkbnMtcmVib290LWxvY2s\"}" | head -c 300; echo; done'
```

(Key `L2NvcmVkbnMtcmVib290LWxvY2s` is base64 of `/coredns-reboot-lock`. If you get JSON with `"kvs":[]` or `"count":"0"` the endpoint is reachable; if timeout or empty, etcd is unreachable from that pod.)

- If every endpoint times out or returns nothing, fix **network/DNS** so pods on that node can reach the etcd Service (e.g. `etcd-0.etcd.kube-system.svc.cluster.local:2379`).
- Ensure **ETCD_ENDPOINTS** in the vlan-manager ConfigMap lists **all** etcd endpoints (comma-separated), e.g. `http://etcd-0.etcd.kube-system.svc.cluster.local:2379,http://etcd-1....,http://etcd-2....`. Update the ConfigMap and restart the DaemonSet if needed.

After fixing connectivity, the script will either see the lock as deleted (if you already ran the delete below) or will correctly see who holds the lock.

### 3. Unstick the reboot lock (other nodes stuck: "Lock held by …" or "Lock held by unknown")

If one node already completed (config updated and node back) but the **other nodes** keep logging "Lock held by …" or "Lock held by unknown", the key `/coredns-reboot-lock` is still in etcd. The controller deletes it when it finishes a job; if it wasn't deleted (e.g. controller didn't run that path) or the key was re-created, the other nodes will never acquire the lock.

**Fix: delete the reboot lock in etcd.** Then the next critical node can acquire the lock and proceed.

```bash
kubectl exec -n kube-system etcd-0 -- env ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 del /coredns-reboot-lock
```

- If nodes are **offline** and waiting for config: after deleting the lock, the controller will process their jobs (and apply config + boot).
- If nodes are **online** and stuck in the DaemonSet loop: after deleting the lock, on the next retry one of them will acquire the lock, write its job, shut down, and the controller will process it.

### 4. All nodes shut down, all jobs marked failed

**Why did all nodes go down? (serialized_shutdown and critical-node were working.)**

- **serialized_shutdown** and the **critical node** logic were working as designed: in a small cluster (e.g. ≤3 nodes) every node is treated as critical, so each node **waits to acquire** `/coredns-reboot-lock` before writing its job and shutting down. So only **one** node holds the lock at a time and only one node shuts down at a time.
- The controller is supposed to **wait** for that node to go offline, then do config-update + boot, and **only then** delete the lock so the next node can acquire.
- What went wrong: the controller **did not** wait. When it saw "node running, config mismatch", it checked whether this job's node was the lock holder. Because of a **bug** (job `node_name` empty or not matching the lock value), it decided "not the lock holder" and **marked the job failed and deleted the lock**. So the lock was released **before** the node had gone offline and been updated. The next waiting node then acquired the lock, wrote its job, and shut down. The controller did the same again: failed the job and deleted the lock. So in sequence: Node1 lock → shutdown → controller fails job, deletes lock → Node2 lock → shutdown → controller fails, deletes lock → … → **all nodes shut down**. Serialization was "one at a time", but the controller kept releasing the lock immediately, so every node got to acquire and shut down in turn.
- Fixes applied: job payload and DaemonSet now set **node_name** correctly; controller trims and compares it to the lock holder; controller **retries failed jobs when the Linode is offline** so recovery is possible without manual etcd edits.

**Second failure mode: etcd quorum lost (controller released lock too early).**

- The controller used to delete the reboot lock as soon as the Linode status was **running**. That only means the machine booted at the OS level; **etcd (and other pods) on that node may not be running yet**. So the next node acquired the lock and shut down while only **one** etcd member was up → no quorum, etcd unusable.
- The DaemonSet had a special case that allowed shutdown when etcd had only **1–2 members**, which let the second node shut down and leave 1 member (no quorum).
- **Fixes applied:** (1) **Controller** now waits for **etcd quorum** (≥ 2 healthy endpoints, up to 10 min) after the Linode is running, then deletes the reboot lock. So the node we just booted has time to get etcd (and pods) back before the next node can shut down. (2) **DaemonSet** no longer allows shutdown when Total ≤ 2; it only allows when SafeAfterShutdown ≥ Quorum (so we never drop below quorum).

If every node shut down and the controller had marked all jobs as **failed**, the cluster has no nodes running and the controller is not running either.

**Step 1 – Boot at least one node**

- In Linode Cloud Manager (or API), **boot one Linode** that belongs to this cluster (use its current config; no need to change config first).
- Wait until that node is **Running** and the control plane sees it. The vlan-config-controller pod will start (or be scheduled) on that node.

**Step 2 – Delete reboot lock (so the controller doesn't wait for a lock holder)**

```bash
kubectl exec -n kube-system etcd-0 -- env ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 del /coredns-reboot-lock
```

(If etcd is not ready yet, wait for the node to be Ready and etcd to be up, then run the command.)

**Step 3 – Let the controller recover failed jobs**

With the **latest** controller script (that retries failed jobs when the Linode is offline):

- The controller sees jobs with status **failed**.
- For each failed job it checks the Linode status; if the Linode is **offline**, it resets the job to **pending** and processes it (config-update + boot).
- So the controller will apply config and boot each offline Linode one by one. No need to manually reset job status in etcd.

If your controller does **not** have this logic yet, update the ConfigMap with the latest `07-vlan-config-controller-scripts.sh`, restart the deployment, then run Step 2 again if needed. After that, the controller will auto-retry failed jobs when the Linode is offline.

### 5. Before redeploying the latest script

1. Run **1**, **2** (check connectivity), **3** (delete reboot lock), and **4** (all nodes down) above as needed.
2. Redeploy the controller (e.g. update the ConfigMap for `07-vlan-config-controller-scripts.sh` and restart the deployment).

### Quick reference (etcd keys)

| Key | Purpose |
|-----|--------|
| `/vlan-config-controller/leader` | Leader lock; delete to allow another replica to become leader. |
| `/coredns-reboot-lock` | Reboot serialization; delete to allow processing any pending job (not only the lock holder). |
| `/vlan-config/<LINODE_ID>` | Job payload (desired interfaces, status). |

---

*Add new Day 2 procedures below this line as they come up.*
