# Linode LKE VLAN Orchestration

Linode Kubernetes Engine doesn't let you attach a VLAN (or VPC) interface at node-pool creation time, and attaching one to an existing node requires a Linode API config-update **and a reboot** — there's no live-attach path. This repository automates that entire dance for every node in your cluster, continuously, so worker nodes end up with a private VLAN (and optionally a VPC) interface without you ever touching a node by hand.

It works for both **LKE Standard** and **LKE Enterprise** clusters — the interface layout, VLAN interface naming, CoreDNS setup, and Linode Cloud Firewall handling are all detected/branched per cluster type. See [Supported cluster types](#supported-cluster-types) below.

---

## How it works

1. A DaemonSet, `vlan-manager`, runs on every worker node and checks whether that node's Linode config already has a VLAN interface attached.
2. If not, it allocates a free IP from your VLAN subnet via `vlan-ip-controller` (a small REST API backed by etcd, using an atomic compare-and-swap so concurrent nodes can never grab the same IP), writes the desired interface configuration into etcd, and shuts the node down.
3. `vlan-config-controller` (leader-elected, watching etcd) notices the pending job, calls the Linode API to update the node's config with the new interface, and the node boots back up.
4. `vlan-manager` starts again on boot, confirms the VLAN interface is now present, pushes any configured static routes/firewall rules/`iptables` hardening, and labels the node `vlan-ready=true`. A Kyverno policy requires that label via `nodeSelector` on every application pod — that, not the node's `vlan-not-ready` taint (which is permanent and deliberately never removed), is what actually unblocks scheduling there (see [Architecture components](#architecture-components) below).

This repeats for every node, including ones added later by scaling the pool up manually or via the cluster autoscaler (with caveats — see [Autoscaling caveats](#autoscaling-caveats) below).

**The chicken-and-egg problem this creates:** the very node that etcd, `vlan-config-controller`, or CoreDNS happen to be running on could be the one getting shut down for its own VLAN attach — taking the thing that's supposed to orchestrate the process down with it. This repo solves that with a dedicated, tainted **`infra-pool`** node pool that `vlan-manager` never touches (see [Why a dedicated `infra-pool`](docs/DEPLOYMENT.md#why-a-dedicated-infra-pool-node-pool) in the deployment guide).

For the full mechanics — the exact etcd key layout, how the interface build order is decided, and how the VLAN interface's real name gets confirmed on the node — see [Architecture](docs/DEPLOYMENT.md#architecture) in the deployment guide.

---

## Supported cluster types

Set `LKE_CLUSTER_TYPE` in `manifests/00-vlan-manager-configmap.yaml` to `standard` or `enterprise` — this drives several branches in the automation:

| | LKE Standard | LKE Enterprise |
|---|---|---|
| Default interface layout | `eth0` = Public | `eth0` = VPC, `eth1` = Public |
| VLAN interface lands at | `eth1` (next available) | `eth2` (next available) |
| Interface build order | Public → VLAN → VPC | VPC → Public → VLAN |
| CoreDNS | Single `coredns` Deployment | Split into `workload-coredns` + `coredns-autoscaler` |
| Typical CNI | Calico | Cilium |
| `ENABLE_FIREWALL` | Honored as configured | **Always ignored/skipped** — LKE-E ships its own managed firewall, and this feature's rules are Calico-specific (see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md), entry 11) |

VLAN interface detection itself doesn't rely on guessing a name — `get_vlan_interface_name()` in `scripts/02-script-vlan-attach.sh` looks up the real IP address Linode assigned to the VLAN interface and matches it against the node's live interfaces, only falling back to the table above if that lookup times out.

---

## Features

- Fully automated, continuous VLAN (and optional VPC) attachment via `00-Orchestration-Script.sh` and the `vlan-manager` DaemonSet — works for nodes present at deploy time and nodes added later
- Atomic, etcd-backed IP allocation (compare-and-swap) — safe under concurrent node onboarding
- Site-to-Site VPN support: static routes pushed onto the VLAN interface specifically (with `onlink` support for gateways outside the node's own VLAN subnet), never the public/VPC interface
- Optional Linode Cloud Firewall creation and optional VLAN east-west `iptables` hardening (blocks new inbound connections on the VLAN interface while allowing established/related traffic)
- Dedicated, tainted `infra-pool` node pool isolating etcd, `vlan-config-controller`, CoreDNS, and Kyverno from the reboot cycle they orchestrate, with `PodDisruptionBudgets` protecting etcd quorum and controller availability from voluntary node scale-down
- Two-layer app-pod scheduling gate: a permanent `vlan-not-ready` node taint (set at node-pool creation/config time, so it's present on every node — including autoscaled/recycled ones — from the moment it joins, with no boot-time race) paired with a Kyverno policy (a CEL-based `MutatingPolicy` on any current cluster, with an automatic fallback to the legacy `ClusterPolicy` type on an older Kyverno install) that mutates every application pod to add the matching toleration plus a required `nodeSelector` on the node's `vlan-ready=true` label, which only gets set once VLAN attach actually completes. Two independent projects' Kyverno policies can each own this gate with zero coordination or collision risk — see [docs/DAY2-OPERATIONS.md](docs/DAY2-OPERATIONS.md#applying-the-vlan-not-ready-taint) for the full mechanics and the design history behind it
- Optional, scripted cutover (`post-migration-consolidate.sh`) to retire `infra-pool` once migration has converged, moving etcd/controller/CoreDNS onto regular nodes via a required `vlan-ready=true` node affinity instead
- Health checks and leader-election/lease-based self-healing (`vlan-config-controller` survives crashes and pod restarts without stranding a job or leaking its leader lock)
- Optional VLAN IP pool reconciliation (`vlan-ip-reconciler` CronJob): automatically detects and releases orphaned IP allocations left behind when nodes are deleted or recycled, before they exhaust the pool — see [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md#vlan-ip-pool-reconciliation)

---

## Architecture components

| Component | What it is | Runs on |
|---|---|---|
| `vlan-manager` | DaemonSet; detects missing VLAN/VPC, allocates an IP, writes the job, shuts the node down, and reconfigures routes/firewall/`iptables` once the interface is back | Every node **except** `infra-pool` |
| `vlan-ip-controller` | Flask REST API; atomic IP allocation/release backed by etcd | Any node (never pinned to `infra-pool`) |
| `vlan-config-controller` | Leader-elected controller; watches etcd for pending jobs and applies the Linode API config-update | `infra-pool` |
| `etcd` | Source of truth for job queue, IP allocation state, and the controller's leader lock | `infra-pool` |
| CoreDNS | Cluster DNS (manually pinned to `infra-pool` — it's an LKE-managed add-on, not part of this repo's manifests) | `infra-pool` |
| Kyverno + `linode-lke-vlan-gating` policy | Mutates app pods to require `vlan-ready=true` and tolerate the permanent taint below; installed automatically, gated by `ENABLE_KYVERNO` | `infra-pool` (pinned post-install) |
| `vlan-not-ready` taint | Permanent node taint; app pods only get past it via Kyverno's injected toleration above | Every app-pool node, permanently |

Full detail on each component, including the exact etcd keys involved and a step-by-step walkthrough of a single node's VLAN attach, lives in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md#architecture).

---

## Prerequisites

1. A Kubernetes cluster running on Linode LKE (Standard or Enterprise)
2. `kubectl` configured with cluster access, and `linode-cli` configured with your API token (`linode-cli configure`)
3. A StorageClass available on Linode for Persistent Volumes (etcd's data disks)
4. A dedicated `infra-pool` node pool created **before** you deploy anything else — minimum 3 nodes (etcd's pod anti-affinity needs 3 distinct hosts to schedule at all); see [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md#why-a-dedicated-infra-pool-node-pool) for the full rationale
5. Autoscaling **disabled** (fixed Min = Max) on every pool `vlan-manager` will actually run on — i.e. everything except `infra-pool`. This isn't optional: an autoscaling app pool will fight this automation the moment the first node gets shut down for VLAN attachment (see [Autoscaling caveats](#autoscaling-caveats))

Every configurable setting (`SUBNET`, `VLAN_LABEL`, `ROUTE_LIST`, `ENABLE_VPC_INTERFACE`, and so on) is documented in full in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md#configuration-reference).

---

## Installation

**1. Create the dedicated `infra-pool` node pool first (minimum 3 nodes).**

Via Cloud Manager: LKE cluster → Node Pools → Add a Node Pool → advanced options → label `infra-pool=true`, taint `infra-pool=true:NoSchedule`. If your LKE plan/version doesn't expose pool-level labels/taints, apply them to each node after it joins instead (less durable across node recycles):
```bash
kubectl label node <node-name> infra-pool=true
kubectl taint node <node-name> infra-pool=true:NoSchedule
```
Also confirm right now that autoscaling is disabled (fixed Min=Max) on the separate pool where `vlan-manager` will run — do this before anything else is deployed.

**2. Pin CoreDNS to `infra-pool` immediately — before deploying etcd or the controller.**

Confirm the actual Deployment name first; it varies by cluster type (see the [Supported cluster types](#supported-cluster-types) table):
```bash
kubectl get deployments -A | grep -i dns
```
Then patch whichever Deployment actually runs CoreDNS:
```bash
kubectl patch deployment <coredns-deployment-name> -n kube-system --type merge -p \
  '{"spec":{"template":{"spec":{"nodeSelector":{"infra-pool":"true"},"tolerations":[{"key":"infra-pool","operator":"Equal","value":"true","effect":"NoSchedule"}]}}}}'
kubectl rollout status deployment/<coredns-deployment-name> -n kube-system
```
Do this now, not after etcd/the controller are already running and depending on DNS — the rolling restart this triggers causes a brief cluster-wide DNS blip, which can cascade into a stranded node if it happens mid-deployment. Re-check after cluster upgrades; some LKE versions periodically reconcile the CoreDNS add-on and silently revert this patch.

**3. Clone the repository:**
```bash
git clone https://github.com/sandipgangdhar/Linode-LKE-Private-Network.git
cd Linode-LKE-Private-Network
```

**4. Confirm your target cluster, then create your ConfigMap and Secret from the provided templates:**
```bash
kubectl config current-context
```
This repo ships only `.example.template.yaml` placeholder files — the real, filled-in files are gitignored and never committed. `LINODE_API_KEY` and `LINODE_CLI_CONFIG` specifically live in a Kubernetes `Secret`, not the ConfigMap — a native Kubernetes object requiring no extra install, kept separate so the token isn't sitting in plaintext alongside non-sensitive settings. Create both locally:
```bash
cd manifests
cp 00-vlan-manager-configmap.example.template.yaml 00-vlan-manager-configmap.yaml
cp 00-vlan-manager-secret.example.template.yaml 00-vlan-manager-secret.yaml
```
Edit `manifests/00-vlan-manager-configmap.yaml` and set the correct `REGION`, `SUBNET`, `VLAN_LABEL`, `LKE_CLUSTER_ID`, `LKE_CLUSTER_TYPE` (`standard` or `enterprise`), and VPC settings for this specific cluster. Edit `manifests/00-vlan-manager-secret.yaml` and set your real `LINODE_API_KEY`/`LINODE_CLI_CONFIG` — or better, skip writing the token to a file at all and create the Secret directly:
```bash
kubectl create secret generic vlan-manager-secrets -n kube-system \
  --from-literal=LINODE_API_KEY='<your-token>' \
  --from-file=LINODE_CLI_CONFIG=<path-to-your-linode-cli-ini-file>
```
The orchestration script applies both files as-is and will refuse to run if either is missing — an uncustomized copy of either template will fail or misconfigure your cluster.

**5. Run the orchestration script from inside `manifests/`** (it resolves scripts and applies YAML relative to its own location; you should already be in this directory from step 4):
```bash
chmod +x 00-Orchestration-Script.sh
./00-Orchestration-Script.sh
```

**6. Monitor the rollout:**
```bash
kubectl get pods -n kube-system
```

Full step-by-step detail, including why each step's ordering matters, lives in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md#installation).

---

## Verification

Confirm component placement — etcd, `vlan-config-controller`, and CoreDNS should only be on `infra-pool`; `vlan-manager` only on everything else:
```bash
kubectl get pods -n kube-system -l app=etcd -o wide
kubectl get pods -n kube-system -l app=vlan-config-controller -o wide
kubectl get pods -n kube-system -l app=vlan-manager -o wide
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
```

Check the VLAN IP Controller and DaemonSet rollouts:
```bash
kubectl rollout status deployment/vlan-ip-controller -n kube-system
kubectl rollout status daemonset/vlan-manager -n kube-system
kubectl exec -n kube-system deploy/vlan-ip-controller -- curl -s http://localhost:8080/health
```

Check IPs currently tracked in etcd (via the controller's own API, not a mounted file):
```bash
kubectl exec -n kube-system deploy/vlan-ip-controller -- curl -s http://localhost:8080/api/v1/vlan-ips
```

Validate routes and the taint gate:
```bash
ip route show | grep <DEST_SUBNET>
kubectl get nodes -o json | jq -r '.items[] | select(.spec.taints[]?.key == "vlan-not-ready") | .metadata.name'
```

---

## Updating configuration after deployment

To add a route, enable the VLAN east-west firewall, rotate the Linode API token, or change any other setting on a cluster that's already running: edit the ConfigMap/Secret, `kubectl apply` it, then `kubectl rollout restart` the affected workload so its pods pick up the new values — env vars from a ConfigMap/Secret don't reach already-running pods on their own. For nodes that already have a VLAN attached, this doesn't trigger a reboot; `push_route` and `configure_vlan_ew_firewall` both check current state before changing anything, so it's safe to re-run. Not every setting behaves the same way, though (some only affect newly onboarded nodes, one triggers a real reboot on purpose, one only removes cleanly on a reboot) — full breakdown and copy-paste recipes for the common cases: [docs/DAY2-OPERATIONS.md](docs/DAY2-OPERATIONS.md#updating-configuration-after-deployment).

---

## Migration: retiring `infra-pool`

Once every app-pool node has finished its own VLAN attach cycle (`vlan-ready=true`), you can move etcd, `vlan-config-controller`, and CoreDNS off `infra-pool` and delete it, via:
```bash
cd manifests
./post-migration-consolidate.sh
```
This aborts safely if migration hasn't actually converged yet, re-applies etcd/the controller with a required `vlan-ready=true` node affinity instead of the `infra-pool` pin, re-patches CoreDNS the same way, and verifies nothing's left behind before telling you it's safe to delete the pool (it won't delete the pool for you — that's a deliberate manual step). Full detail, safety checks, and the pool-deletion sequence: [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md#migration-retiring-infra-pool).

### Autoscaling caveats

Retiring `infra-pool` does not, by itself, make it safe to enable autoscaling on the app pool. Two independent risks remain: cluster-autoscaler can misread a node's intentional VLAN-attach shutdown as a health failure and provision a stuck replacement, and it can target a brand-new, still-mid-attach node for scale-down because it looks idle (no app pods yet, by taint design). Both need dedicated handling beyond what's in this repo today — see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md), entry 1.

---

## Uninstallation

Full command and caveats: [docs/DAY2-OPERATIONS.md](docs/DAY2-OPERATIONS.md#uninstallation).

---

## Known limitations

- `manifests/05-vlan-ip-initializer-job.yaml` references `/mnt/vlan-ip/` but doesn't mount the `vlan-ip-pvc` PVC — see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md), entry 9.
- The optional Linode Cloud Firewall (`ENABLE_FIREWALL`) hardcodes Calico-oriented rules (BGP, Typha, IPIP) and is only meaningful on Standard/Calico clusters — it's automatically skipped on Enterprise (see the cluster-type table above and [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md), entry 11).
- `linode-cli` must be configured with a valid API token before running anything.
- The PVC used by the initializer job must be released before re-deployment; if the initializer job gets stuck, check PVC permissions.

For anything not covered here, [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) has the fuller list of scenarios encountered and fixed in this project (stuck leader locks, `Pending` etcd/controller pods, slow first IP allocation, node-pool autoscaler runaway growth, and more).

---

## Contributing

Feel free to open issues and submit PRs to enhance the automation and deployment experience.

---

## License

MIT License. See `LICENSE` for more information.

---

## Support

For any issues, please contact [sandip.gangdhar@gmail.com](mailto:sandip.gangdhar@gmail.com).
