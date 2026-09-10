# Deployment Guide: Linode LKE VLAN Orchestration

This guide covers installing, verifying, migrating, and uninstalling the Linode LKE VLAN Orchestration solution. For a high-level explanation of what this solves and how the pieces fit together, see the main [README](../README.md#how-it-works).

---

## Overview

Linode doesn't support specifying a VLAN at node-pool creation time, and attaching one to an existing node requires a config-update **and a reboot** — there's no live-attach path. This solution automates that cycle continuously: a DaemonSet (`vlan-manager`) detects a node missing its VLAN interface, allocates an IP, hands off to a leader-elected controller (`vlan-config-controller`) that applies the Linode API change, and the node reboots with the interface attached.

That reboot cycle is also the reason this guide leads with a dedicated node pool, below — if etcd, the controller, or CoreDNS land on a node that gets cycled for its own VLAN attach, you can lose the very thing meant to orchestrate the process.

---

## Architecture

### Components

| Component | Type | What it does | Where it runs |
|---|---|---|---|
| `vlan-manager` | DaemonSet (`manifests/07-vlan-manager-daemonset.yaml`, script `scripts/02-script-vlan-attach.sh`) | Runs on every node. On each invocation, checks whether the node's Linode config already has a VLAN interface (and, if configured, a VPC interface). If not: allocates a free VLAN IP, writes the desired interface state into etcd, and shuts the node down. Once the node reboots with the new interface, it pushes any configured static routes, the optional Linode Cloud Firewall, optional VLAN east-west `iptables` rules, and labels the node `vlan-ready=true`. | Every node except `infra-pool` |
| `vlan-ip-controller` | Deployment, Flask REST API (`manifests/06-vlan-ip-controller-deployment.yaml`, script `scripts/06-rest-api.py`) | Allocates and releases VLAN IPs. Scans the Linode account/region for IPs already in use, and hands out free ones from `SUBNET` via an atomic etcd compare-and-swap so two nodes requesting an IP at the same time can never collide. Exposes `/health`, `/allocate`, `/release`, and `/api/v1/vlan-ips`. | `infra-pool` — **not** `app-pool`, unlike earlier in this repo's history: pinning it to `app-pool` let a burst of simultaneous VLAN attaches on that pool leave it with zero eligible nodes, causing a live-confirmed 100+-pod creation storm (no ReplicaSet backoff for repeated pod-creation failure). See [Troubleshooting](TROUBLESHOOTING.md) entry 22 and the [Migration](#migration-retiring-infra-pool) section below. |
| `vlan-config-controller` | Deployment, leader-elected (`manifests/10-vlan-config-controller.yaml`, script `scripts/07-vlan-config-controller-scripts.sh`) | The only component with 2 replicas that coordinate via a lease-backed leader election. The active leader polls etcd for pending interface-change jobs, calls the Linode API to apply the config-update, and marks the job as applied. | `infra-pool` |
| `etcd` | StatefulSet (`manifests/08-etcd-StatefulSet-3node.yaml` or `-1node.yaml`) | Source of truth for: the interface-change job queue, IP allocation state, and `vlan-config-controller`'s leader lock. Nothing in this system keeps state anywhere else. | `infra-pool` |
| CoreDNS | LKE-managed add-on (not part of this repo's manifests — patched manually) | Cluster DNS. Manually pinned to `infra-pool` because the rest of this system depends on DNS resolving reliably (to reach the Kubernetes API, etcd's headless service, and the Linode API). | `infra-pool` |
| Kyverno + `linode-lke-vlan-gating` policy | `MutatingPolicy` (`manifests/09-kyverno-vlan-ready-mutatingpolicy.yaml`, CEL-based `policies.kyverno.io/v1`) on any cluster whose Kyverno ships the `mutatingpolicies.policies.kyverno.io` CRD, else the legacy `ClusterPolicy` (`manifests/09-kyverno-vlan-ready-policy.yaml`) as a fallback for an older Kyverno install. `apply_kyverno_policy()` in `00-Orchestration-Script.sh` (gated by `ENABLE_KYVERNO`) detects which CRD is available and applies exactly one of the two, deleting the other type if a stale copy is present — see that function and `mutating_policy_crd_available()`. The legacy `ClusterPolicy` type is deprecated as of Kyverno v1.19 and scheduled for removal in v1.20 (~October 2026); a fresh install on any reasonably current Kyverno gets the `MutatingPolicy` automatically. | Mutates every application Pod (excluding `kube-system`/`kyverno`/`kube-public`/`kube-node-lease`, plus — `MutatingPolicy` only — any namespace labeled `kyverno-mutation-exempt=true`) to add `nodeSelector: vlan-ready: "true"` and a toleration for the `vlan-not-ready` taint — with zero changes required to the Pod's own spec. Uses a flat `nodeSelector` map (not `nodeAffinity`/`nodeSelectorTerms`) and an append (JSON-Patch `op: add` in both policy types) for the toleration list specifically so a second, independent project's Kyverno policy can add its own key/toleration without ever colliding — see the header comment in each policy file for the full history of why this replaced an earlier, collision-prone design. | Kyverno itself is pinned to `infra-pool` post-install (its upstream manifest ships with no tolerations of its own) |
| `vlan-not-ready` taint | Node taint, configured at node-pool creation/config time on the **app pool** (Cloud Manager/`linode-cli`/Terraform — see [Applying the vlan-not-ready taint](DAY2-OPERATIONS.md#applying-the-vlan-not-ready-taint)) | The static half of a two-layer scheduling gate. This taint is **permanent and deliberately never removed** — LKE reconciles pool-level taints back onto every node in the pool indefinitely (confirmed empirically), so trying to clear it per-node once VLAN attach completes is a fight against the platform that can't be won. Its job now is pure defense-in-depth: any pod that somehow doesn't get Kyverno's mutation (webhook briefly down, a namespace nobody added to the exclude list, etc.) still can't land on an unready node, because it lacks the toleration — it just sits `Pending` visibly instead of running somewhere broken. The actual dynamic "is this node ready" signal is the `vlan-ready=true` node **label**, set once by `mark_node_vlan_ready()` in `scripts/02-script-vlan-attach.sh` and never touched by anything external, which is what Kyverno's `nodeSelector` injection above actually gates on. `vlan-manager`'s own DaemonSet tolerates *any* taint on this node (not just this one), so it can still run here even if a sibling project's own permanent taint also lands on this same pool — see [Coexisting with other Kyverno-gated projects](#coexisting-with-other-kyverno-gated-projects) below — with an explicit `nodeAffinity` keeping it off `infra-pool` instead of relying on an untolerated taint. See `manifests/07-vlan-manager-daemonset.yaml`. | Every app-pool node, permanently |

### How a single node's VLAN attach actually happens, step by step

1. `vlan-manager`'s pod on the node runs `scripts/02-script-vlan-attach.sh`, which calls the Linode API (`linode-cli linodes config-view`) to read the node's current interface list.
2. If no `purpose: vlan` interface is present, the script calls `vlan-ip-controller`'s `/allocate` endpoint, which does an atomic etcd compare-and-swap on `/vlan/ip/<ip>` to reserve a free address from `SUBNET` without any risk of two nodes getting the same IP even if they ask at the same instant.
3. The script builds the node's *complete* desired interface list (existing Public/VPC interfaces preserved exactly as they are, new VLAN interface appended in the position dictated by `LKE_CLUSTER_TYPE` — see [Interface layout by cluster type](#interface-layout-by-cluster-type) below) and writes it to etcd at `/vlan-config/<linode-id>` with `status: "pending"`. It then reads the key back from etcd and compares the value before proceeding, specifically so it never shuts a node down on the strength of a write that didn't actually commit.
4. The script calls `serialized_shutdown` and powers the node off via the Linode API.
5. `vlan-config-controller`'s active leader (elected via a lease at `/vlan-config-controller/leader`) is continuously polling etcd for keys under `/vlan-config/` with `status: "pending"`. When it sees this node's job, it calls the Linode API's config-update endpoint with the desired interface list, marks the etcd key `status: "applied"`, and the Linode API automatically brings the instance back up once its config is updated.
6. The node boots. Kubelet and the `vlan-manager` DaemonSet pod start again, the script re-runs, sees the VLAN interface now present, and exits the "needs attach" path entirely — it pushes routes/firewall/`iptables` rules (if configured) and labels the node `vlan-ready=true`. That label is what actually unblocks application pods from scheduling there — Kyverno's `linode-lke-vlan-gating` policy requires it via `nodeSelector` on every application Pod (see the Architecture table above). The node's `vlan-not-ready` taint is deliberately left in place; it's permanent by design, not something this step removes.

This whole loop is idempotent and safe to re-run: a node that already has its VLAN interface simply confirms that and moves on to the routing/firewall/labeling steps every time its DaemonSet pod restarts, without re-triggering a shutdown.

### Interface layout by cluster type

Linode assigns interfaces by numeric index (`eth0`, `eth1`, `eth2`, ...) in the order they're declared in the instance config, and LKE's own default layout differs between Standard and Enterprise:

- **LKE Standard** starts with just `eth0 = Public`. This solution appends VLAN next, and (if `ENABLE_VPC_INTERFACE=true`) VPC after that — so the desired order becomes `Public → VLAN → VPC`.
- **LKE Enterprise** starts with `eth0 = VPC, eth1 = Public` already present (LKE-E clusters are provisioned inside a VPC by default). This solution preserves that fixed base and appends VLAN next — `VPC → Public → VLAN`.

`scripts/02-script-vlan-attach.sh`'s `configure_interfaces()` and `build_base_interfaces()` functions branch on `LKE_CLUSTER_TYPE` to build exactly these two orders, and always preserve whatever VPC/VLAN interfaces already exist rather than reconstructing them from scratch — so re-running this on a node that already has some interfaces attached never drops one as a side effect of adding another.

Once attached, the VLAN interface's actual name on the node (`eth1`, `eth2`, or something else entirely) is confirmed dynamically: `get_vlan_interface_name()` reads the VLAN's assigned IP from the Linode API and matches it against the node's live interfaces (`ip addr show`), retrying for up to 30 seconds. Only if that lookup fails entirely does it fall back to a hardcoded guess — `eth2` for Enterprise, `eth1` for Standard, matching the layouts above.

### Why a dedicated `infra-pool` node pool

`vlan-manager` works by **shutting a node down**, waiting for `vlan-config-controller` to notice via the Linode API, applying the interface change, and booting it back up. If etcd, `vlan-config-controller` itself, or CoreDNS happen to be scheduled on the node being cycled, you either lose etcd quorum, lose the component that's supposed to notice the shutdown and reconcile, or lose cluster DNS mid-rollout. The code has a `serialized_shutdown` lock/quorum-check fallback for exactly this case (see `scripts/02-script-vlan-attach.sh`), but it's a safety net, not something to rely on routinely — see [Troubleshooting](TROUBLESHOOTING.md) entry 8.

The fix: isolate these three components on a separate node pool that is **tainted**, so `vlan-manager` never schedules there and never touches those nodes at all.

**Minimum size: 3 nodes.** This isn't a preference — `manifests/08-etcd-StatefulSet-3node.yaml` has `requiredDuringSchedulingIgnoredDuringExecution` pod anti-affinity on etcd, so a 3-member etcd cluster needs 3 distinct nodes to schedule at all. `vlan-config-controller` (2 replicas, its own anti-affinity) and CoreDNS fit within those same 3 nodes — they don't need extra nodes of their own, just distinct hosts from their sibling replicas. Losing 1 of the 3 infra nodes still leaves etcd at quorum (2/3) and at least one controller/CoreDNS replica standing. Go to 4 nodes only if you want headroom to drain one for maintenance without ever touching bare-minimum quorum. These nodes can be small/cheap plans — none of the three components define heavy CPU/memory requests.

---

## Prerequisites

1. A Kubernetes cluster running on **Linode LKE** (Standard or Enterprise)
2. `kubectl` configured with cluster access
3. `linode-cli` configured with your API token:
    ```bash
    linode-cli configure
    ```
4. `jq` available locally (used by `00-Orchestration-Script.sh`'s `ensure_app_pool_taint()` to safely merge node-pool taints — see [Coexisting with other Kyverno-gated projects](#coexisting-with-other-kyverno-gated-projects) below — and by several commands in this guide)
5. A StorageClass created on Linode for Persistent Volumes (etcd's data disks)
6. **A dedicated `infra-pool` node pool, labeled/tainted, in place before etcd/`vlan-config-controller` deploy** — see [Installation](#installation) step 1. Either create and label/taint it yourself beforehand, or let `AUTO_CREATE_INFRA_POOL=true` create it as part of the same orchestration run (see step 1's Option A) — either way, without it the etcd and `vlan-config-controller` pods will sit `Pending` (nothing matches their `nodeSelector`).
7. **Autoscaling must be DISABLED (fixed node count) on whichever pool(s) `vlan-manager` will run on** — i.e. every pool *except* `infra-pool`. This is not optional. `vlan-manager` powers nodes off and back on directly via the Linode API as a normal part of VLAN attachment. If the pool autoscales, LKE's autoscaler sees a node go temporarily unresponsive mid-attach, decides capacity is short, and provisions a brand-new replacement node to compensate — while the original node sits there stuck offline with nothing cleaning it up. Repeat across every node going through the attach cycle and the pool balloons toward its max while filling up with dead, stuck nodes. Set Min = Max = your intended fixed node count (Cloud Manager: pool's `•••` menu → Autoscale settings → disable, or set both bounds equal). See [Troubleshooting](TROUBLESHOOTING.md) entry 1 if this has already happened.

---

## Configuration reference

Non-sensitive settings live in the `vlan-manager-config` ConfigMap (`manifests/00-vlan-manager-configmap.yaml`; a documented starting point with placeholder values is at `manifests/00-vlan-manager-configmap.example.template.yaml`). All values are strings, including booleans and numbers, because ConfigMap `data` values are always strings. `LINODE_API_KEY` and `LINODE_CLI_CONFIG` live separately, in the `vlan-manager-secrets` Secret — see [Secrets vs ConfigMap](#secrets-vs-configmap) below.

| Key | Values | Default in template | What it controls |
|---|---|---|---|
| `LKE_CLUSTER_TYPE` | `standard` \| `enterprise` | `enterprise` | Selects the interface build order, VLAN interface fallback name, and whether the Linode Cloud Firewall feature is honored at all. See [Interface layout by cluster type](#interface-layout-by-cluster-type). |
| `ENABLE_VLAN` | `true` \| `false` | `true` | Master switch for the VLAN attach feature. If `false`, `vlan-manager` never allocates an IP or attempts a VLAN attach at all. |
| `SUBNET` | CIDR, e.g. `10.95.255.0/24` | — (required) | The VLAN-side subnet `vlan-ip-controller` allocates addresses from. The network address, first usable host, and broadcast address are automatically reserved and never handed out. |
| `VLAN_CIDR` | CIDR, e.g. `10.95.0.0/16` | unset (falls back to `SUBNET`'s own prefix) | The VLAN's real, full physical CIDR — set this only when `SUBNET` is deliberately narrower than the VLAN's actual extent (e.g. scoped to avoid another party's reserved sub-block on the same VLAN). When set, every node's VLAN interface is configured with `VLAN_CIDR`'s prefix instead of `SUBNET`'s, so the interface's kernel-connected route covers the whole VLAN rather than just the narrower allocation pool — otherwise a node can't reach another host physically on the same VLAN but outside `SUBNET`'s own range (a NAT gateway, a NAT fleet node, etc.), even though they share the same wire. `SUBNET` must nest inside `VLAN_CIDR`; `vlan-ip-controller` rejects `/allocate` requests with a 400 otherwise. Only affects newly-allocated IPs (new node onboarding) — hot-reloads via `kubectl rollout restart deploy/vlan-ip-controller` like `SUBNET` itself, but does not retroactively reconfigure already-attached nodes. |
| `VLAN_LABEL` | string | — (required) | The VLAN label as it will appear in Linode's own VLAN configuration. |
| `REGION` | Linode region slug, e.g. `gb-lon`, `in-maa` | — (required) | Used both for the VLAN/Linode API calls and to filter the instance scan in `vlan-ip-controller`. |
| `LKE_CLUSTER_ID` | numeric string | — (required) | Used to name/label the optional Linode Cloud Firewall (`lke-cluster-firewall-<id>`) on Standard clusters. |
| `APP_POOL_ID` | numeric string, comma-separated for more than one pool | `""` | If you created the app-pool(s) yourself and any don't carry the `app-pool=true` label yet, their pool id(s) — `ensure_app_pool_taint()` applies the label (never touching existing taints) to each pool listed automatically, then runs its taint-merge logic against every pool that ends up labeled (both pre-existing and newly-bootstrapped). A cluster can have more than one app-pool. Bootstrap-only per pool — an id is irrelevant once that pool's label exists, so it's safe to leave old ids in the list. Leave empty to apply labels by hand instead. See [Installation](#installation) step 1. |
| `CACHE_TTL_SECONDS` | integer seconds, `"0"` disables | `"30"` | How long `vlan-ip-controller` caches its full account/region IP scan before re-scanning. Doesn't affect correctness (the real duplicate-allocation guard is an atomic etcd compare-and-swap) — only affects how often `/allocate` has to do a slow, full serial scan. See [Troubleshooting](TROUBLESHOOTING.md) entry 6. |
| `LOG_LEVEL` | `DEBUG` \| `INFO` \| `WARN` \| `ERROR` | `INFO` (also the fallback for an unset or unrecognized value) | Verbosity for `vlan-manager`, `vlan-ip-controller`, `vlan-ip-initializer`, `vlan-config-controller`, and `vlan-ip-reconciler` — every component except etcd, which has its own fixed `--log-level` flag in the StatefulSet manifest, independent of this key. `DEBUG` adds per-candidate/per-item detail (every IP allocation candidate considered, every lost CAS race, per-page/per-instance scan progress) useful for troubleshooting but too noisy for routine operation. Optional — safe to leave unset on an existing deployment (every `configMapKeyRef` referencing it is marked `optional: true`), and hot-reloads via `kubectl rollout restart` like any other ConfigMap-sourced env var. |
| `ENABLE_PUSH_ROUTE` | `true` \| `false` | `true` | Whether to push the static routes in `ROUTE_LIST` onto each node's VLAN interface — typically used for Site-to-Site VPN reachability to external networks (AWS, GCP, on-prem, etc.). |
| `ROUTE_LIST` | YAML list of `route_ip`/`dest_subnet` pairs | (example VPN routes) | One or more `{route_ip, dest_subnet}` pairs. `route_ip` is the gateway on the VLAN side (e.g. your NAT/VPN server's VLAN IP); `dest_subnet` is what should route through it. Pushed with the `onlink` flag so a gateway outside the node's own VLAN `/24` (but still L2-reachable on the larger flat VLAN) doesn't get rejected by the kernel as an invalid nexthop. |
| `ENABLE_FIREWALL` | `true` \| `false` | `false` | Whether to create/attach a Linode Cloud Firewall to worker nodes. **Ignored entirely on `LKE_CLUSTER_TYPE=enterprise`** — see [Troubleshooting](TROUBLESHOOTING.md) entry 11 for why. |
| `ENABLE_VPC_INTERFACE` | `true` \| `false` | `false` | Whether to attach/manage a VPC interface. If `false` but a VPC interface already exists on the node for some other reason (e.g. LKE Enterprise's default layout), it's always preserved as-is — this flag only gates *creating* a new one, never removing an existing one. |
| `VPC_SUBNET_ID` | numeric string | — (required if `ENABLE_VPC_INTERFACE=true`) | The Linode VPC subnet ID to attach as the VPC interface. |
| `ENABLE_VLAN_EW_FIREWALL` | `true` \| `false` | `false` | Whether to apply the two VLAN east-west `iptables` rules (accept established/related, drop new inbound) on the VLAN interface. Independent of `ENABLE_FIREWALL` — see [Troubleshooting](TROUBLESHOOTING.md) for a plain-language explanation of exactly what these two rules do. |
| `MAX_CONCURRENT_JOBS` | integer | `"5"` | How many pending VLAN/VPC reconfigure jobs `vlan-config-controller` processes at once instead of one at a time. See [Job concurrency and failure handling](#job-concurrency-and-failure-handling-in-vlan-config-controller). |
| `JOB_WAIT_TIMEOUT_SECONDS` | integer seconds | `"300"` | How long `vlan-config-controller` waits for a Linode instance to report `offline`/`running` before giving up on that one job. See [Job concurrency and failure handling](#job-concurrency-and-failure-handling-in-vlan-config-controller). |
| `KUBECONFIG` | file path | `/tmp/kubeconfig` | Path inside the pod where the generated kubeconfig is written. Not a credential itself — see the note below. |
| `AUTO_CREATE_INFRA_POOL` | `true` \| `false` | `false` | Opt-in: let `00-Orchestration-Script.sh` create `infra-pool` for you instead of doing it by hand. See [Installation](#installation) step 1. |
| `INFRA_POOL_PLAN` | Linode plan/type id, e.g. `g6-standard-2` | `""` | Required only if `AUTO_CREATE_INFRA_POOL=true`. No safe default — plan availability and cost are a real per-account/region choice this script won't guess at. |
| `INFRA_POOL_NODE_COUNT` | integer | `"3"` | `3` is the documented **minimum**, not just a default — etcd's pod anti-affinity needs 3 distinct nodes. Raise it for more headroom (e.g. many CoreDNS replicas). Used to create the pool (`AUTO_CREATE_INFRA_POOL=true`) and as a sanity check against a manually-created pool's actual count either way. |
| `INFRA_POOL_ID` | numeric string | `""` | If `AUTO_CREATE_INFRA_POOL=false` and you created `infra-pool` yourself, its pool id — `ensure_infra_pool()` applies the label/taint to this exact pool automatically. Leave empty to apply the label/taint by hand instead, as before this automation existed. |

### Secrets vs ConfigMap

`LINODE_API_KEY` and `LINODE_CLI_CONFIG` are **not** in the ConfigMap — they live in a separate `vlan-manager-secrets` Secret (`manifests/00-vlan-manager-secret.yaml`; template at `manifests/00-vlan-manager-secret.example.template.yaml`). A Kubernetes `Secret` is a built-in API object on every LKE cluster (Standard and Enterprise), so this requires no additional installation — no Vault, no External Secrets Operator, no Sealed Secrets controller.

| Key | Values | What it controls |
|---|---|---|
| `LINODE_API_KEY` | string (secret) | Linode API token used by `linode-cli` and the REST API (`vlan-ip-controller`). |
| `LINODE_CLI_CONFIG` | INI file content (secret) | The full `linode-cli` config file content (same token as `LINODE_API_KEY`, plus region/user settings), mounted or exported into each pod that shells out to `linode-cli`. |

What moving these into a Secret actually buys you, and what it doesn't:

- **RBAC-gated read access.** `03-vlan-manager-rbac.yaml` grants `vlan-manager-sa` `get`/`watch` on exactly this one Secret by name (`resourceNames: ["vlan-manager-secrets"]`), not a blanket grant on all Secrets in the namespace. A ConfigMap has no equivalent way to restrict who can read a single key.
- **Less casual exposure.** The token no longer shows up in a plain `kubectl get configmap vlan-manager-config -o yaml`, and tooling that treats Secrets specially (log scrapers, backup tools, `kubectl` output redaction) is less likely to dump it accidentally.
- **Not encryption at rest.** A Kubernetes Secret is base64-encoded in etcd, not encrypted, unless the control plane has `--encryption-provider-config` set. LKE's managed control plane does not currently expose this option, so this is honestly still not "encrypted at rest" in the strict sense — it's a real, meaningful access-control improvement over a plaintext ConfigMap, not a cryptographic one.
- **The token's own scope still matters most.** Whatever the Secret protects, the actual blast radius if it ever leaks is determined by what the underlying Linode API token can do. Scope it as narrowly as Linode's per-category token permissions allow, and rotate it periodically — the Secret is not a substitute for that.

Create the Secret either by copying and editing the template (`cp 00-vlan-manager-secret.example.template.yaml 00-vlan-manager-secret.yaml`), or, to avoid ever writing the real token to a file on disk, imperatively:
```bash
kubectl create secret generic vlan-manager-secrets -n kube-system \
  --from-literal=LINODE_API_KEY='<your-token>' \
  --from-file=LINODE_CLI_CONFIG=<path-to-your-linode-cli-ini-file>
```
The Secret is marked `immutable: true` in the template — to rotate the token, delete and recreate the Secret, then roll the pods that consume it (`kubectl rollout restart daemonset/vlan-manager deployment/vlan-config-controller deployment/vlan-ip-controller -n kube-system`).

**Note on `KUBECONFIG`:** the DaemonSet doesn't actually need a stored kubeconfig secret at all — `07-vlan-manager-daemonset.yaml` generates one at container startup from the pod's automatically-mounted, automatically-rotated ServiceAccount token (`/var/run/secrets/kubernetes.io/serviceaccount/token`), which Kubernetes provisions with zero configuration. `KUBECONFIG` in the ConfigMap is just the file path that kubeconfig gets written to, not credential material.

---

## Installation

**1. Create the dedicated `infra-pool` node pool (do this first), and the app pool with its `vlan-not-ready` taint, and confirm the app pool has autoscaling disabled:**

First, find your cluster ID if you don't already have it:
```bash
linode-cli lke clusters-list
```

**infra-pool: two ways to get there, pick one.**

*Option A — let the script create it for you.* Set `AUTO_CREATE_INFRA_POOL: "true"` and `INFRA_POOL_PLAN: "<a Linode plan/type id>"` in your ConfigMap (see [Configuration reference](#configuration-reference)) before running `00-Orchestration-Script.sh` — `ensure_infra_pool()` creates the pool with the correct label and taint set together, waits for its nodes to join, and pins CoreDNS to it automatically, all before etcd/the controller are deployed. Node count comes from `INFRA_POOL_NODE_COUNT` (default `3`, the documented minimum — see below). This is opt-in and off by default: creating a node pool spins up real, billed Linode instances, which is a meaningfully bigger action than anything else this script automates on its own, so it only happens if you explicitly ask for it. If you go this route, skip straight to step 2's note about CoreDNS already being handled, and to step 3.

*Option B — create it yourself, the script only labels/taints it.* Create the pool manually (any way you like — `linode-cli`, Cloud Manager, Terraform), deciding plan and count yourself, then either apply the label/taint by hand (below) or just note the pool's numeric id and put it in `INFRA_POOL_ID` in the ConfigMap — `ensure_infra_pool()` will find it by that id and apply the label/taint for you automatically on the next run, so you never have to hand-type `--labels`/`--taints.*` syntax yourself (a genuinely easy place to make a silent, destructive mistake — see the taint-replace warning further down). Minimum 3 nodes either way (required by etcd's pod anti-affinity, see [Why a dedicated infra-pool node pool](#why-a-dedicated-infra-pool-node-pool) below) — raise this if you expect to need more headroom, e.g. a large cluster running many CoreDNS replicas.

**Applying the label/taint fully by hand** (only needed if you're not using `INFRA_POOL_ID`/`AUTO_CREATE_INFRA_POOL`, or want to understand what the automation above does under the hood) — set both together in a single call:
```bash
linode-cli lke pool-create <cluster-id> --type <plan> --count 3 \
  --labels '{"infra-pool":"true"}' \
  --taints.key infra-pool --taints.value true --taints.effect NoSchedule
```
(No `.0.` index on `--taints.*` — `linode-cli lke pool-create --help` confirms the flat `--taints.key`/`--taints.value`/`--taints.effect` form; an indexed form fails with `unrecognized arguments`. `--labels` takes a JSON object, confirmed via `--help` since it has no documented sub-flags of its own.) Setting both in the same `pool-create` call, rather than two separate calls, also sidesteps a real gotcha: a *second* `pool-update` call with different `--taints.*` values **replaces** the pool's taints array instead of appending to it — harmless here since this is a single create call, but worth knowing before you ever need to update this pool's taints later (see [Applying the vlan-not-ready taint](DAY2-OPERATIONS.md#applying-the-vlan-not-ready-taint)).

Or via Cloud Manager: LKE cluster → Node Pools → Add a Node Pool → under advanced options, add label `infra-pool=true` and taint `infra-pool=true:NoSchedule`.

If your LKE plan/version doesn't expose pool-level taints in the UI or CLI at all, fall back to tainting nodes directly after they join (less durable — LKE recreates nodes on recycle without preserving this, so you'd need to reapply):
```bash
kubectl label node <node-name> infra-pool=true
kubectl taint node <node-name> infra-pool=true:NoSchedule
```

**If `infra-pool` already exists** (you created the pool itself but haven't set its label/taint yet, or you're retrofitting this onto an existing cluster), find its pool ID and `pool-update` it instead of `pool-create` — set the label and taint together in the same call for the same reason as above:
```bash
linode-cli lke pools-list <cluster-id> --json | jq '.[] | {id, type, count, taints, labels}'   # find infra-pool's id
linode-cli lke pool-update <cluster-id> <pool-id> \
  --labels '{"infra-pool":"true"}' \
  --taints.key infra-pool --taints.value true --taints.effect NoSchedule
```
**If you need to add the taint in a separate call from the labels for any reason, do the taint call first and the labels call second** (or combine them as above) — `--taints.*` and `--labels` are independent fields and don't disturb each other, but **two separate `pool-update` calls that each set `--taints.*`** will clobber one another: the second call's taints array *replaces* the first's rather than merging with it, silently wiping out whatever taint the first call set. Confirmed the hard way on a live cluster — see [Applying the vlan-not-ready taint](DAY2-OPERATIONS.md#applying-the-vlan-not-ready-taint) for the full story. If a pool ever needs more than one taint, set them all in the same `--taints.*` call, not across multiple calls.

**Also create the app pool `vlan-manager` will actually run on, labeled `app-pool=true` so it's auto-discoverable** — the label itself matters as much as the taint here: `ensure_app_pool_taint()` in `00-Orchestration-Script.sh` finds this pool via the label on every deploy and keeps its `vlan-not-ready` taint in place automatically (merging with, never replacing, any other project's taint already there — see [Coexisting with other Kyverno-gated projects](#coexisting-with-other-kyverno-gated-projects) below), so you generally only need to set the taint by hand this once, at first creation:
```bash
linode-cli lke pool-create <cluster-id> --type <plan> --count <N> \
  --labels '{"app-pool":"true"}' \
  --taints.key vlan-not-ready --taints.value true --taints.effect NoSchedule
```
Or the equivalent in Cloud Manager's node pool taint UI / your Terraform — just make sure the `app-pool=true` label is set either way, or the orchestration script won't be able to find this pool automatically.

**This label is mandatory, not just a discovery convenience.** Every VLAN component (`vlan-manager` DaemonSet, `vlan-ip-controller`, the initializer Job, the IP reconciler CronJob) requires `app-pool=true` via `nodeAffinity` before it will schedule anywhere. If your cluster has more than the two pools this guide describes — e.g. a 3rd pool created for something unrelated — that pool is excluded by default and gets nothing deployed to it, unless you deliberately add the `app-pool=true` label to it too. There's no "runs everywhere except infra-pool" fallback anymore: only pools you've explicitly labeled `app-pool=true` get VLAN attached.

**If the app pool already exists without this label** (predates this convention, or was created by a sibling project first), you have two options:

*Option A — let the script apply the label for you.* Put the pool's numeric id in `APP_POOL_ID` in the ConfigMap (find it with `linode-cli lke pools-list <cluster-id> --json | jq '.[] | {id, type, count, labels}'`) and re-run `00-Orchestration-Script.sh` — `ensure_app_pool_taint()` applies the `app-pool=true` label to that exact pool automatically (a `--labels`-only `pool-update` call, which never touches the pool's existing taints — `--labels` and `--taints.*` are independent fields on this endpoint), then continues straight into its normal taint-merge logic in the same run. This is bootstrap-only: once the label exists, every future deploy — this project's or a sibling's — finds the pool via the label itself, exactly as it always has; `APP_POOL_ID` only ever matters the one time the label doesn't exist yet.

**More than one app-pool.** A cluster can legitimately have more than one app-pool — e.g. different instance types for different workloads, all gated by the same `vlan-ready` mechanism. List every not-yet-labeled pool's id in `APP_POOL_ID`, comma-separated (`"123456,789012"`); a single id with no comma still works exactly as before. `ensure_app_pool_taint()` labels each one, then runs its taint-merge logic against *every* pool that ends up carrying the label — both ones already labeled before this run and ones just bootstrapped via this list — so all of them get the `vlan-not-ready` taint, not just the first one found.

*Option B — add the label by hand.* `pool-update` replaces labels/taints wholesale, so include whatever's already there in the same call:
```bash
linode-cli lke pools-list <cluster-id> --json | jq '.[] | {id, type, count, taints, labels}'   # find the app pool's id, check its current taints/labels

linode-cli lke pool-update <cluster-id> <pool-id> \
  --labels '{"app-pool":"true"}' \
  --taints.key vlan-not-ready --taints.value true --taints.effect NoSchedule
  # add --taints.key/.value/.effect again for each other taint already
  # present (e.g. a sibling project's own), in this same call
```
Either way, once the label is set, `ensure_app_pool_taint()` takes over on every future deploy — this manual step (or `APP_POOL_ID`) is only needed the one time a pool doesn't have the label yet.

**Confirm both pools landed correctly before moving on:**
```bash
linode-cli lke pools-list <cluster-id> --json | jq '.[] | {id, type, count, taints, labels}'
```
`infra-pool` should show the `infra-pool` taint and label; the app pool should show the `vlan-not-ready` taint and the `app-pool` label (plus any other project's own taint, if one is already sharing this pool).

**Also confirm right now that autoscaling is OFF (fixed Min=Max) on this app pool** — see Prerequisite #6. Do this before deploying anything else; an autoscaling app pool and this automation will actively fight each other the moment the first node gets shut down for VLAN attachment.

**2. Pin CoreDNS to `infra-pool` immediately — before deploying etcd or the controller:**

**If you used Option A or B above with `ensure_infra_pool()`, this already happened automatically** — `auto_pin_coredns()` runs as part of the same step, right after infra-pool is confirmed present, and before etcd/the controller are deployed. It auto-detects the actual Deployment name (see below for why that varies) and skips cleanly if it's already pinned or can't confidently identify a single CoreDNS deployment. Confirm it worked: `kubectl get deployment <coredns-deployment-name> -n kube-system -o jsonpath='{.spec.template.spec.nodeSelector}'` should show `{"infra-pool":"true"}`. If it doesn't — e.g. `jq` wasn't available, or your cluster has more than one deployment matching "coredns" and the script deliberately declined to guess — fall back to the manual steps below.

**Manual path — first confirm the actual deployment name, it varies by LKE type/version.** Standard LKE typically names it `coredns`; LKE Enterprise clusters seen in this project instead split it into `workload-coredns` (the actual DNS Deployment) + a separate `coredns-autoscaler` (only adjusts `workload-coredns`'s replica count via the scale subresource — it won't fight this patch). Don't assume the name; check it:
```bash
kubectl get deployments -A | grep -i dns
```

Then patch whichever Deployment actually runs CoreDNS (substitute the real name for `<coredns-deployment-name>`):
```bash
kubectl patch deployment <coredns-deployment-name> -n kube-system --type merge -p \
  '{"spec":{"template":{"spec":{"nodeSelector":{"infra-pool":"true"},"tolerations":[{"key":"infra-pool","operator":"Equal","value":"true","effect":"NoSchedule"}]}}}}'
kubectl rollout status deployment/<coredns-deployment-name> -n kube-system
```
For example, on Standard LKE this is usually:
```bash
kubectl patch deployment coredns -n kube-system --type merge -p \
  '{"spec":{"template":{"spec":{"nodeSelector":{"infra-pool":"true"},"tolerations":[{"key":"infra-pool","operator":"Equal","value":"true","effect":"NoSchedule"}]}}}}'
```
On LKE Enterprise it's typically:
```bash
kubectl patch deployment workload-coredns -n kube-system --type merge -p \
  '{"spec":{"template":{"spec":{"nodeSelector":{"infra-pool":"true"},"tolerations":[{"key":"infra-pool","operator":"Equal","value":"true","effect":"NoSchedule"}]}}}}'
```

**Do this now, not after the rest of the stack is running.** This patch triggers a CoreDNS rolling restart, which causes a brief cluster-wide DNS disruption while it reschedules onto the new pool. If etcd and `vlan-config-controller` are already up and depending on DNS when that happens, the disruption can cascade — e.g. a node's `02-script-vlan-attach.sh` can get a non-committing response from etcd mid-write and (pre-fix) proceed to shut the node down with no job ever durably recorded, stranding it offline. Getting this restart out of the way before anything else depends on DNS avoids that entirely.

Re-check this after any cluster upgrade — some LKE versions periodically reconcile the CoreDNS add-on and can silently revert the patch.

**Nothing else needs manual pinning to `infra-pool` at this stage.** Kyverno (see the Architecture table above) gets installed and pinned to `infra-pool` automatically as part of step 5 below, gated by `ENABLE_KYVERNO` in the ConfigMap (defaults `"true"` in the template — leave it unless you have a specific reason to disable the gating policy).

**3. Clone the repository:**
```bash
git clone https://github.com/sandipgangdhar/Linode-LKE-Private-Network.git
cd Linode-LKE-Private-Network
```

**4. Confirm `kubectl config current-context` points at the target cluster, then create your ConfigMap and Secret from the provided templates.**

Only the two `.example.template.yaml` files are committed to this repo — documented placeholder files with dummy values. The real `manifests/00-vlan-manager-configmap.yaml` and `manifests/00-vlan-manager-secret.yaml` are intentionally never committed (both are gitignored). `LINODE_API_KEY` and `LINODE_CLI_CONFIG` specifically live in the Secret, not the ConfigMap — see [Secrets vs ConfigMap](#secrets-vs-configmap) below for why. Create both locally by copying the templates:
```bash
cd manifests
cp 00-vlan-manager-configmap.example.template.yaml 00-vlan-manager-configmap.yaml
cp 00-vlan-manager-secret.example.template.yaml 00-vlan-manager-secret.yaml
```
Edit the new `manifests/00-vlan-manager-configmap.yaml` and fill in the correct `REGION`, `SUBNET`, `VLAN_LABEL`, `LKE_CLUSTER_ID`, `LKE_CLUSTER_TYPE` (`standard` or `enterprise`), and VPC settings for this specific cluster (see [Configuration reference](#configuration-reference) for every key).

Edit the new `manifests/00-vlan-manager-secret.yaml` and fill in your real `LINODE_API_KEY`/`LINODE_CLI_CONFIG` — or skip the file entirely and create the Secret imperatively instead, so the token is never written to disk:
```bash
kubectl create secret generic vlan-manager-secrets -n kube-system \
  --from-literal=LINODE_API_KEY='<your-token>' \
  --from-file=LINODE_CLI_CONFIG=<path-to-your-linode-cli-ini-file>
```
The orchestration script applies both files exactly as it finds them, and refuses to run at all if either is missing (a preflight check at the top of `00-Orchestration-Script.sh` checks for both before Step 1). If you skip this step, or forget to replace a placeholder value, the script will either exit immediately or misconfigure the cluster with dummy settings.

**5. Make the orchestration script executable and run it from inside `manifests/`** (it resolves the scripts directory and applies YAML relative to its own location, so it must run from there; you should already be in this directory from step 4):
```bash
chmod +x 00-Orchestration-Script.sh
./00-Orchestration-Script.sh
```

**6. Monitor the deployment:**
```bash
kubectl get pods -n kube-system
```

---

## Verification

1. **Check component placement** — etcd, `vlan-config-controller`, CoreDNS, and Kyverno should only be on `infra-pool` nodes; `vlan-manager` should only be on the other (app-tier) nodes:
    ```bash
    kubectl get pods -n kube-system -l app=etcd -o wide
    kubectl get pods -n kube-system -l app=vlan-config-controller -o wide
    kubectl get pods -n kube-system -l app=vlan-manager -o wide
    kubectl get pods -n kyverno -o wide
    ```
    For CoreDNS, confirm the actual Deployment name first rather than assuming a label (Standard LKE typically uses `coredns`/`k8s-app=kube-dns`; LKE Enterprise has been seen using `workload-coredns` with a different selector — see Installation step 2):
    ```bash
    kubectl get deployments -n kube-system -o name | grep -i dns
    kubectl get pods -n kube-system -l "$(kubectl get deployment <coredns-deployment-name> -n kube-system -o jsonpath='{.spec.selector.matchLabels}' | jq -r 'to_entries|map("\(.key)=\(.value)")|join(",")')" -o wide
    ```

2. **Check the VLAN IP Controller (REST API) is healthy:**
    ```bash
    kubectl rollout status deployment/vlan-ip-controller -n kube-system
    kubectl exec -n kube-system deploy/vlan-ip-controller -- curl -s http://localhost:8080/health
    ```

3. **Check the VLAN Manager DaemonSet:**
    ```bash
    kubectl rollout status daemonset/vlan-manager -n kube-system
    ```

4. **Check IPs currently tracked in etcd** (via the controller API, not a mounted file):
    ```bash
    kubectl exec -n kube-system deploy/vlan-ip-controller -- curl -s http://localhost:8080/api/v1/vlan-ips
    ```

5. **Verify routes:**
    ```bash
    ip route show | grep <DEST_SUBNET>
    ```

6. **Confirm the two-layer scheduling gate is actually working.** The `vlan-not-ready` taint is now permanent on every app-pool node by design, so checking for its presence no longer tells you anything about readiness — check the dynamic signal (`vlan-ready` label) and confirm Kyverno is really injecting the mutation instead:
    ```bash
    # Every app-pool node should show vlan-ready=true once its VLAN attach
    # has completed - this, not the taint, is what indicates readiness now.
    kubectl get nodes -L vlan-ready -o json | jq -r '.items[] | "\(.metadata.name)\t\(.metadata.labels."vlan-ready")"'

    # Confirm the policy is installed and Kyverno actually mutated a real
    # pod - deploy anything with zero special config and check its spec:
    kubectl run verify-vlan-gating --image=nginx -n default
    kubectl get pod verify-vlan-gating -o yaml | grep -A6 tolerations
    kubectl get pod verify-vlan-gating -o jsonpath='{.spec.nodeSelector}'
    kubectl delete pod verify-vlan-gating -n default
    ```
    You should see `vlan-not-ready` injected into `tolerations` and `{"vlan-ready":"true"}` in `nodeSelector`, with zero changes made to the pod spec you submitted, and the pod actually `Running` on an app-pool node (not stuck `Pending`).

---

## Coexisting with other Kyverno-gated projects

This applies if another project sharing this cluster — currently `lke-e-acl-operator` is the one that exists — also uses a permanent taint + Kyverno scheduling gate (`ClusterPolicy` or `MutatingPolicy`) on the same app-pool. **Deploy order between this project and a sibling project does not matter** — either can go first — but only because of the specific things below. Skip this section entirely if this is the only such project on the cluster.

### What's actually shared between two projects

Two things on the cluster are genuinely shared, not per-project:

1. **The Kyverno installation itself.** Kyverno is cluster-scoped — there's exactly one installation, one set of controller pods, regardless of how many policy objects (of either type) target it. Whichever project's installer runs first actually installs Kyverno; the second one detects it's already present and skips reinstalling.
2. **The app-pool**, if both projects choose to put their application-facing workloads there. Each project sets its own permanent node taint at pool-creation/`pool-update` time, and both taints end up on the *same* pool.

Everything else — each project's own policy object, its own node-ready label, its own operator pods — stays fully independent, by design (see the header comment in `manifests/09-kyverno-vlan-ready-mutatingpolicy.yaml` (or `09-kyverno-vlan-ready-policy.yaml` on the legacy fallback path) for the full coexistence mechanics: a flat `nodeSelector` map plus an append-only JSON Patch for tolerations, so a second project's policy can never collide with this one no matter which order Kyverno evaluates them in, and no matter whether the two projects are on different policy types at a given moment).

### What had to be fixed to make that actually true

Four real gaps were found and closed by reading `lke-e-acl-operator`'s own code and docs directly (its `00-orchestration.sh`, `manifests/06-kyverno-acl-gating-policy.yaml`, and `docs/deployment-guide.md`), not just assumed safe by design:

1. **`install_kyverno()` used to skip pinning Kyverno's own pods whenever it found Kyverno already installed.** If a sibling project installed Kyverno first without pinning it anywhere itself, Kyverno's pods would end up with zero `nodeSelector`/toleration on a cluster where every pool now carries a custom taint — looking completely healthy at deploy time (already-running pods aren't evicted by a taint added later) and then failing the next time any Kyverno pod got rescheduled, with nowhere left to land. `install_kyverno()` in `00-Orchestration-Script.sh` now always re-checks and re-applies the `infra-pool` pinning, whether Kyverno was just installed or already present.
2. **That same pinning patch used to replace the tolerations list wholesale** instead of appending to it, which would have silently wiped out any toleration a sibling project's own install had already added the same way. It's now an idempotent check-then-append (JSON Patch), never a blind replace.
3. **Every `kube-system` workload that runs on the app-pool** (`vlan-manager`, `vlan-ip-initializer`, `vlan-ip-controller`, `vlan-ip-reconciler`, and their `post-migration/` equivalents) only tolerated its own `vlan-not-ready` taint. A node needs *all* its taints tolerated to accept a pod — the moment a sibling project's taint also landed on that same app-pool, none of them could schedule there anymore, in either deploy order. All of them now tolerate any taint (`operator: Exists`), matching the same pattern `lke-e-acl-operator`'s own `lke-acl-agent` DaemonSet already uses. Pool isolation no longer depends on which taints happen to be un-tolerated — each of these now carries a required `nodeAffinity` on the `app-pool=true` **label** instead. This started as an "exclude `infra-pool`" rule, but that only isolates correctly on a cluster with exactly two pools; a 3rd/4th pool with no label and no taint would otherwise silently receive these workloads too (see [Installation step 1](#installation) for why the `app-pool=true` label is now a hard scheduling requirement, not just a discovery convenience).
4. **Setting the app-pool's taint used to be a manual, human-run `pool-update` call** — meaning whoever deployed second had to remember to check `pools-list` and combine their taint with whatever a sibling project had already set, or silently wipe it out. `ensure_app_pool_taint()` in `00-Orchestration-Script.sh` now does this automatically on every deploy: it finds the app-pool via its `app-pool=true` label (see [Installation step 1](#installation)), reads whatever taints are already there, and re-submits the full set — its own plus everyone else's — in one `pool-update` call, skipping entirely if its own taint is already present. This is genuinely safe for any number of future projects, not just two: it never needs to know another project's taint key in advance, it just never removes what it didn't add.

None of this changes the commands you run — `./00-Orchestration-Script.sh` is unchanged either way, still just one command. It changes what that script (and the static manifests it applies) actually do under the hood, so that no manual coordination step is needed regardless of which project reaches the cluster first, or how many join later.

### The one remaining manual step: the very first taint, on a pool that has no label yet

`ensure_app_pool_taint()` needs the app-pool to already carry the `app-pool=true` label to find it — see [Installation step 1](#installation) for setting that label (and the taint) the first time a pool is created, and for the one-time retrofit command if an existing app-pool predates this label convention. Once the label exists, every future deploy — this project's or any sibling's — keeps the taint list correct automatically; the label itself is the only thing that has to be set by a human, once, ever, per pool.

### What lives in the other project's repo, not here

The exemption mechanism differs by policy type, and **this matters if either project migrates from `ClusterPolicy` to `MutatingPolicy`** (confirmed live: `resourceFilters` only governs Kyverno's legacy JMESPath engine — a `MutatingPolicy` ignores it entirely, so an exemption that only exists in that ConfigMap silently stops protecting a namespace the moment the *other* project's policy becomes a `MutatingPolicy`, even though this repo's own policy never changed):

- **Legacy `ClusterPolicy` path:** `lke-e-acl-operator` exempts its own operator namespace from *this* project's `linode-lke-vlan-gating` `ClusterPolicy` (and from any other `ClusterPolicy` on the cluster) by adding itself to Kyverno's own global `resourceFilters` ConfigMap — evaluated before any legacy-engine policy runs, so it doesn't need to reference this policy by name.
- **`MutatingPolicy` path (the one a fresh deploy actually gets — see the Architecture table above):** `resourceFilters` doesn't apply, so exemption instead uses a namespace-label convention: any namespace that needs to be exempt from mutation-based cluster automation labels itself `kyverno-mutation-exempt=true` (`kubectl label namespace <ns> kyverno-mutation-exempt=true`), and this project's own `MutatingPolicy` (`manifests/09-kyverno-vlan-ready-mutatingpolicy.yaml`) excludes any namespace carrying that label via its `namespaceSelector`. `lke-e-acl-operator` already labels its own namespace this way as of its own migration to `MutatingPolicy`. Neither repo ever needs to reference the other's namespace name — only this one shared, documented label key — so nothing here needs to change if a third project joins later.

In both cases, this repo's own `kube-system` workloads get the equivalent protection for free: it's in the fixed system-namespace exclude list both policy types carry (`resourceFilters` for the legacy engine, the hardcoded `namespaceSelector` values for `MutatingPolicy`) — no equivalent addition needed on this side. If you're deploying alongside `lke-e-acl-operator` specifically, its own `docs/deployment-guide.md` documents the ACL-specific side of this — that's out of scope for this repo by design, the same way this repo's own Kyverno mechanics aren't duplicated into theirs.

---

## Migration: Retiring `infra-pool`

Once every app-pool node has finished its own VLAN attach cycle (each one carries `vlan-ready=true`), you can move etcd, `vlan-config-controller`, CoreDNS, and Kyverno off `infra-pool` and onto the regular app-pool nodes, then delete `infra-pool` entirely. This is the natural next step right after a successful deployment converges — this section is optional, though; leaving `infra-pool` in place permanently is a perfectly reasonable choice (see the cost/complexity discussion in [Troubleshooting](TROUBLESHOOTING.md) if you want the trade-offs spelled out).

**Every workload this migration moves needs an explicit `vlan-not-ready` toleration as part of the move**, since app-pool's taint is permanent (see [Applying the vlan-not-ready taint](DAY2-OPERATIONS.md#applying-the-vlan-not-ready-taint) in Day 2 Operations) and all of these are `kube-system`/`kyverno`-namespace workloads, deliberately excluded from Kyverno's own `linode-lke-vlan-gating` policy — nothing auto-injects this for them the way it does for application pods. The `post-migration/` manifests and `post-migration-consolidate.sh`'s Kyverno patch already include it; this is just why, if you ever hand-roll a variant of this migration, don't drop that toleration by copying the pre-migration (`infra-pool`-pinned) manifests as a starting point without adding it back.

**Why this is safe only after migration, not from day one:** on a brand-new cluster, zero nodes start out `vlan-ready=true` — nothing has gone through VLAN attach yet. If etcd/the controller required that label from the start, they'd have nowhere to schedule, and `vlan-config-controller` is the exact thing needed to make any node *become* `vlan-ready` in the first place (it can't bootstrap itself). `infra-pool` exists specifically to break that chicken-and-egg problem at cluster creation time. Once the cluster has converged, though, plenty of already-`vlan-ready` nodes exist, so repointing etcd/controller at that label is safe — they simply reschedule onto nodes that already qualify.

### Run the cutover script

```bash
cd manifests
./post-migration-consolidate.sh
```

This script (see comments in the file for full detail):
1. Aborts if any app-pool node is not yet `vlan-ready=true` — the hard guard against the bootstrap problem above.
2. Re-applies etcd (`post-migration/08-etcd-StatefulSet-3node.yaml`) and `vlan-config-controller` (`post-migration/10-vlan-config-controller.yaml`) — identical workloads to the ones deployed today, but with `infra-pool` nodeSelector/toleration replaced by a `requiredDuringSchedulingIgnoredDuringExecution` nodeAffinity on `vlan-ready=true` plus an explicit `vlan-not-ready` toleration (needed because that taint is permanent — see above).
3. Re-applies `vlan-ip-controller` (`post-migration/06-vlan-ip-controller-deployment.yaml`) the same way. `vlan-ip-controller` is pinned to `infra-pool` pre-migration (not `app-pool`, unlike earlier in this repo's history) specifically to avoid a live-confirmed bug: with it on `app-pool`, multiple/all app-pool nodes going through their own VLAN/VPC attach cycle at the same time left it with zero eligible nodes, and Kubernetes' ReplicaSet controller rapid-fire created and failed well over a hundred replacement pod objects in seconds with no backoff. See [Troubleshooting](TROUBLESHOOTING.md) entry 22.
4. Re-patches CoreDNS the same way (auto-detects `coredns` vs `workload-coredns`).
5. Re-patches Kyverno's 4 Deployments the same way, in the `kyverno` namespace (not `kube-system`) — Kyverno gets pinned to `infra-pool` automatically on install (see [Applying the vlan-not-ready taint](DAY2-OPERATIONS.md#applying-the-vlan-not-ready-taint) step 2 in Day 2 Operations), so this undoes that pinning the same way CoreDNS's is undone.
6. Re-patches the other LKE-managed `kube-system` workloads `auto_pin_lke_system_components()` (`00-Orchestration-script.sh`) pins to `infra-pool` for the same reason as Kyverno — `cilium-operator`, `calico-kube-controllers`, `calico-typha-autoscaler`, `coredns-autoscaler`, `konnectivity-agent`, `konnectivity-autoscaler`, `konnectivity-agent-autoscaler`, and the `csi-linode-controller` StatefulSet (whichever of these actually exist on this cluster type — checked defensively, not all apply to both Standard and Enterprise). The konnectivity autoscaler's Deployment name isn't consistent across cluster types — `konnectivity-autoscaler` on Enterprise, `konnectivity-agent-autoscaler` on Standard — confirmed live after the wrong single name left it stuck `Pending` indefinitely on a Standard cluster (existence checks can only skip a name that doesn't exist, not detect "exists under a different name"), so both names are listed explicitly rather than picking one. Skipping this step doesn't just leave a Deployment behind the way skipping Kyverno would — confirmed live, missing it leaves these workloads **permanently orphaned** once `infra-pool` is actually deleted, since `cilium-operator` in particular has no DaemonSet-style fallback placement.
7. Verifies nothing non-DaemonSet is left on `infra-pool` nodes.
8. Prints — but does not run — the commands to cordon and delete the `infra-pool` node pool. Deleting the pool is left as a deliberate manual step.

### Final cross-check before deleting the pool

Step 7 above already runs this, but re-run it standalone right before you delete/scale down the pool, as one last confirmation nothing crept back onto it in the meantime (e.g. hours or days later, once you're actually comfortable removing the rollback path):
```bash
./manifests/check-infra-pool-safe-to-delete.sh
```
This re-runs the same check Step 7 does, and — only if it passes — prints the exact `kubectl cordon` / `linode-cli lke pool-delete` commands ready to copy-paste, with the real cluster id and pool id already resolved (read from the `vlan-manager-config` ConfigMap and the Linode API respectively). It never runs anything destructive itself — deleting the pool stays a deliberate, manual action on purpose (see the script's own header comment for why: `infra-pool` nodes still existing is this project's entire rollback path if something about the migration turns out to be wrong after the fact).

**Expected output: no non-DaemonSet pods on any `infra-pool` node.** A genuinely clean migration leaves zero. Earlier revisions of this doc described `cilium-operator`/`coredns-autoscaler`/`konnectivity-agent`/`konnectivity-autoscaler` as expected to remain here, "tolerating all taints by design" — that was true only before this project's app-pool taint became permanent from day one. Confirmed live: none of these actually tolerate a custom taint by default, and step 6 above exists specifically to move them too. If any of them (or `csi-linode-controller`) show up here after running the full script, that step failed partway through for it — investigate the script's own output for that workload rather than assuming it's expected. `etcd-*`, `vlan-config-controller-*`, `workload-coredns`/`coredns-*`, Kyverno's Deployments, a bare/standalone debug pod someone left behind (see [Troubleshooting](TROUBLESHOOTING.md) entry 24), or any pod outside `kube-system` showing up here is the same real red flag it always was.

If you'd rather see the raw check without the script (e.g. no `linode-cli` available locally):
```bash
for NODE in $(kubectl get nodes -l infra-pool=true -o jsonpath='{.items[*].metadata.name}'); do
  kubectl get pods -A --field-selector spec.nodeName="$NODE" -o json | \
    jq -r --arg node "$NODE" '.items[] | select([.metadata.ownerReferences[]? | select(.kind == "DaemonSet")] | length == 0) | "\($node): \(.metadata.namespace)/\(.metadata.name)"'
done
```

If you want to see *every* pod on these nodes (DaemonSets included) rather than just the non-DaemonSet ones, drop the `jq` filter:
```bash
for NODE in $(kubectl get nodes -l infra-pool=true -o jsonpath='{.items[*].metadata.name}'); do
  echo "== $NODE =="
  kubectl get pods -A --field-selector spec.nodeName="$NODE" -o wide
done
```

### Deleting the `infra-pool` node pool itself

Resize down to 1 node first rather than deleting the whole pool outright — it's more easily reversible (scaling back up just re-adds nodes with the same pool-level label/taint config; recreating a deleted pool means redoing that setup from scratch), and it lets you confirm the pool's remaining LKE system pods reschedule cleanly on a smaller blast radius before the final, irreversible delete.

```bash
# 1. Confirm nodes are cordoned first (if not already done) - this closes the
#    window for anything new to land there while you do the rest of this.
kubectl cordon -l infra-pool=true

# 2. Find your cluster ID (if you don't already have it handy)
linode-cli lke clusters-list

# 3. Find the infra-pool's pool ID. Labels/taints applied via `kubectl label`/
#    `kubectl taint` (rather than at pool creation) won't show up as a
#    filterable field here, so list all pools and match manually - by node
#    count, and by cross-referencing the `nodes[].instance_id` values against
#    `kubectl get nodes -l infra-pool=true -o wide` (IPs will match).
linode-cli lke pools-list <cluster-id> --json | jq '.[] | {id, type, count, nodes}'

# 4. Resize infra-pool from 3 to 1 (use the pool id confirmed in step 3)
linode-cli lke pool-update <cluster-id> <pool-id> --count 1

# 5. Watch the 2 removed nodes leave and everything reschedule cleanly
kubectl get nodes -l infra-pool=true
kubectl get pods -A -o wide | grep -E 'cilium-operator|coredns-autoscaler|konnectivity'

# 6. Re-run the cross-check on whatever infra-pool node is left
for NODE in $(kubectl get nodes -l infra-pool=true -o jsonpath='{.items[*].metadata.name}'); do
  kubectl get pods -A --field-selector spec.nodeName="$NODE" -o json | \
    jq -r --arg node "$NODE" '.items[] | select([.metadata.ownerReferences[]? | select(.kind == "DaemonSet")] | length == 0) | "\($node): \(.metadata.namespace)/\(.metadata.name)"'
done

# 7. If that's clean and DNS/cluster function look normal, delete the pool
#    (LKE pool resize typically won't go to 0 - this last node is removed by
#    deleting the pool object itself, not a further resize).
linode-cli lke pool-delete <cluster-id> <pool-id>

# 8. If any stale Node objects remain in Kubernetes after the Linode
#    instances are gone (kubelet sometimes doesn't get a chance to
#    deregister cleanly), remove them manually:
kubectl get nodes -l infra-pool=true
kubectl delete node <stale-node-name>   # only if still listed after step 7
```

**If you plan to leave autoscaling on for the app pool afterward**, retiring `infra-pool` on its own doesn't make that safe by itself. Two separate risks remain: cluster-autoscaler can misinterpret a node's intentional VLAN-attach shutdown as a health failure and spin up a replacement (this is why Prerequisite #6 requires fixed Min=Max autoscaling), and it can also target a brand-new, still-mid-attach node for scale-down because it looks idle (no app pods yet, since Kyverno's `linode-lke-vlan-gating` policy keeps them off until the node is `vlan-ready=true`). Both need dedicated fixes beyond this script — ask if you want those scoped out before enabling autoscaling on that pool.

**Rollback:** if something looks wrong partway through, `infra-pool` nodes are never touched or deleted by this script — re-apply the original manifests (`08-etcd-StatefulSet-3node.yaml`, `10-vlan-config-controller.yaml`), re-patch CoreDNS back to `infra-pool` per Installation step 2, and re-patch Kyverno's 4 Deployments back to `infra-pool` per [Applying the vlan-not-ready taint](DAY2-OPERATIONS.md#applying-the-vlan-not-ready-taint) step 2 in Day 2 Operations (or re-run `install_kyverno()`'s patch from `00-Orchestration-Script.sh`).

---

## Updating configuration after deployment

**This section has moved to [docs/DAY2-OPERATIONS.md#updating-configuration-after-deployment](DAY2-OPERATIONS.md#updating-configuration-after-deployment).** It covers the general apply/rollout-restart mechanism, which ConfigMap/Secret keys behave differently, and copy-paste recipes for static routes, the VLAN east-west firewall, rotating the Linode API token, and reapplying `ETCD_ENDPOINTS`-templated manifests.

---

## VLAN IP pool reconciliation

Deleting or recycling a node — manually, via a crash, or via the cluster autoscaler — never releases the VLAN IP that node was allocated. Nothing in `vlan-manager` or `vlan-config-controller` calls `/release` on node teardown. Every such event leaves a permanent orphan entry in etcd, and left unchecked this silently shrinks the allocatable pool until it's fully exhausted: in production, a `/24 SUBNET` with only 4 real VLAN attachments ended up with all 254 usable addresses marked "used" in etcd, stalling every new node's VLAN attach indefinitely and driving affected `vlan-manager` pods into a permanent `CrashLoopBackOff` (each restart retries allocation, exhausts its 5 attempts, exits, restarts, repeats).

`11-vlan-ip-reconciler-cronjob.yaml` (gated by `ENABLE_IP_RECONCILER` in the ConfigMap) runs `scripts/11-vlan-ip-reconciler.sh` every 15 minutes to catch and fix this automatically:

1. Fetches etcd's "used" IP list from `vlan-ip-controller`'s own `/api/v1/vlan-ips`, filtered to the currently-configured `SUBNET` only.
2. Scans Linode directly for real, current VLAN interface attachments in `REGION` (the same walk `vlan-ip-controller`'s own `fetch_assigned_ips()` does server-side).
3. Excludes any IP tied to a pending/processing job in `/vlan-config/` — a node that's been shut down for its config-update but hasn't had it applied yet will correctly show as "used" in etcd without yet appearing in a live Linode scan; treating that as orphaned would risk a duplicate IP allocation.
4. Whatever's left — used in etcd, not real on Linode, not in-flight — is a candidate. **Nothing is released on first sighting.** A candidate's first-seen timestamp is recorded in etcd (`/vlan-ip-reconciler/candidate/<ip>`), and it's only actually released once it's been seen as a candidate for at least `MIN_CONFIRM_AGE_SECONDS` (default 900s / one full schedule interval).
5. If a single run would release more than `MAX_AUTO_RELEASE_PER_RUN` (default 20) IPs, **none** of them are auto-released — that many at once is far more likely to mean a bug in the scan itself than normal node churn, and auto-releasing through that blindly would make a real failure mode worse. A loud log line is emitted instead, for manual investigation.

This only ever touches IPs inside the currently-configured `SUBNET` — older or unrelated ranges left over from a previous `SUBNET` value (a real thing you may see if this value has ever changed on a long-lived cluster) are deliberately left alone, since reconciling those is a distinct, manual decision.

To reconcile manually right now instead of waiting for the schedule (e.g. mid-incident):
```bash
kubectl create job --from=cronjob/vlan-ip-reconciler vlan-ip-reconciler-manual-$(date +%s) -n kube-system
kubectl logs -f -n kube-system job/vlan-ip-reconciler-manual-<the-timestamp-you-used>
```

---

## Job concurrency and failure handling in `vlan-config-controller`

`vlan-config-controller` previously processed pending VLAN/VPC reconfigure jobs one at a time, with no timeout on the "wait for Linode to report `offline`" or "wait for Linode to report `running`" polling loops. This had a direct customer-facing cost during cluster-autoscaler scale-up bursts: since the `vlan-not-ready` taint blocks real workload pods from scheduling onto a node until it's `vlan-ready=true`, and a new node's VLAN attach couldn't even start until every node ahead of it in the queue had fully finished its own shutdown/reconfigure/boot cycle, the last node in a burst of N new nodes could take roughly N times as long to become usable as a single node normally would. Worse, if any one job ever got stuck (see [Troubleshooting](TROUBLESHOOTING.md) entry 8), every job queued behind it stalled indefinitely too.

**Bounded concurrency (`MAX_CONCURRENT_JOBS`, default `5`):** the controller now processes up to this many pending jobs at once instead of one at a time. This is safe because different Linode instances are independent of each other, and the per-job etcd compare-and-swap (the atomic `pending` → `processing` transition) already prevents two workers from double-processing the same job regardless of how many run concurrently — serial processing was a control-loop limitation, not a correctness requirement. The value is kept bounded rather than unlimited specifically to avoid firing off enough simultaneous shutdown/status-poll/boot cycles to risk Linode API rate limiting during a large scale-up.

**Bounded wait (`JOB_WAIT_TIMEOUT_SECONDS`, default `300`):** each of the two polling loops now gives up after this many seconds instead of waiting forever. On timeout, the job's etcd entry is marked `status: "failed"` with `failure_reason` and `failed_at` fields, and the controller moves on to other queued jobs immediately — it does not retry the failed job itself. In practice this still self-heals in the common case: the `vlan-manager` DaemonSet pod on that node resubmits a fresh `"pending"` job the next time its container restarts and finds VLAN still not attached. A job that keeps failing repeatedly means the underlying Linode instance needs manual investigation (see [Troubleshooting](TROUBLESHOOTING.md) entry 12), not a longer timeout. A failed job's allocated VLAN IP isn't stranded either — since it's no longer `pending`/`processing`, the [IP pool reconciler](#vlan-ip-pool-reconciliation) will eventually reclaim it through its normal two-sighting confirmation process if the node never comes back.

**Related autoscaler protection:** `scripts/02-script-vlan-attach.sh` now annotates a node `cluster-autoscaler.kubernetes.io/scale-down-disabled=true` as soon as it starts running (before it's even determined whether VLAN is attached yet), and clears the annotation once the node reaches `vlan-ready=true`. This closes a related gap: cluster-autoscaler's idle-node detection has no way to know that a node with zero workload pods is mid-onboarding rather than genuinely idle (the `vlan-not-ready` taint is what's keeping real pods off it), and could otherwise pick it as a scale-down candidate before it ever finishes onboarding — wasting the entire attach cycle and forcing the next scale-up attempt to start from zero.

Tune both `MAX_CONCURRENT_JOBS` and `JOB_WAIT_TIMEOUT_SECONDS` the same way as any other ConfigMap value — see [Updating configuration after deployment](DAY2-OPERATIONS.md#updating-configuration-after-deployment). `vlan-config-controller` reads them from its own environment at process start, so a plain `kubectl rollout restart deployment/vlan-config-controller -n kube-system` after updating the ConfigMap (or the `kubectl set env` live-patch shortcut) is enough to pick up a new value — no image rebuild needed.

---

## Uninstallation

**This section has moved to [docs/DAY2-OPERATIONS.md#uninstallation](DAY2-OPERATIONS.md#uninstallation).**

---

## Troubleshooting

All known issues, symptoms, causes, and resolutions live in [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — that's the single source of truth kept in sync with the current code, so start there rather than searching this guide for error messages.
