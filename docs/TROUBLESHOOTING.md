# Troubleshooting Guide: Linode LKE VLAN Orchestration

This document is the single source of truth for known issues, their causes, and their resolutions. `docs/DEPLOYMENT.md` intentionally does not duplicate this content — if you're chasing an error message or unexpected behavior, start here.

Each entry follows the same structure: **Symptom** (what you actually see), **Cause** (why it happens), **Resolution** (how to fix or work around it). Where relevant, a **Diagnosis** section gives the exact commands to confirm you're looking at this specific issue before acting.

---

## 1. Node pool keeps growing (toward its Max) while nodes sit stuck `Offline`

**Symptom:** the app/VLAN pool's node count keeps climbing toward its configured Max in Cloud Manager, while several nodes show as `Offline` in `kubectl get nodes` and never recover on their own.

**Diagnosis:**
```bash
kubectl get nodes -o wide | grep -i notready
```
In Cloud Manager: Node Pools → look for `Autoscaling (Min X / Max Y)` on the pool `vlan-manager` runs on.

**Cause:** the app/VLAN pool has autoscaling enabled. `vlan-manager` shuts nodes down directly via the Linode API as a normal, expected part of VLAN attachment (see [DEPLOYMENT.md](DEPLOYMENT.md#how-a-single-nodes-vlan-attach-actually-happens-step-by-step)). LKE's cluster-autoscaler has no way to know that shutdown is intentional and temporary — it sees a node go unresponsive, concludes the pool is short on capacity, and provisions a brand-new replacement node to compensate. The original node, meanwhile, is still mid-attach and will come back on its own — but the autoscaler doesn't wait to find out. Repeat this once per node going through the attach cycle, and the pool grows toward its Max while filling up with nodes that are stuck offline for no real reason.

**Resolution:** disable autoscaling (or set Min = Max) on the pool `vlan-manager` runs on. This is a hard prerequisite for this automation, not a tuning knob — see [DEPLOYMENT.md](DEPLOYMENT.md#prerequisites) prerequisite #6. `infra-pool` (etcd/controller/CoreDNS) is unaffected by this issue entirely, since nothing ever shuts those nodes down.

Nodes already stuck offline from this need manual cleanup: confirm via `linode-cli events list` that no VLAN config was ever actually applied to them (check `/vlan-config/<linode-id>` in etcd — if the key is empty or missing, the interface update never landed), then either boot them back up to retry once the pool is fixed-size, or remove them and let the pool re-settle at its intended fixed count.

---

## 2. Nodes stay `Offline` with real `pending` jobs sitting in etcd, and BOTH `vlan-config-controller` replicas go completely silent after startup

**Symptom:** `kubectl logs` for both `vlan-config-controller` replicas shows only the startup banner and nothing after — no polling activity, no errors, nothing. Meanwhile nodes that should be getting their VLAN attached sit `Offline` indefinitely.

**Diagnosis:** confirm jobs actually exist and are `pending`:
```bash
kubectl exec -n kube-system deploy/vlan-config-controller -- sh -c \
  'export ETCDCTL_API=3; etcdctl --endpoints=http://etcd-0.etcd.kube-system.svc.cluster.local:2379 get /vlan-config/ --prefix'
```
Then check the leader lock:
```bash
kubectl exec -n kube-system deploy/vlan-config-controller -- sh -c \
  'export ETCDCTL_API=3; etcdctl --endpoints=http://etcd-0.etcd.kube-system.svc.cluster.local:2379 get /vlan-config-controller/leader'
```
If this returns a value — especially one belonging to a pod that shows `RESTARTS > 0` in `kubectl get pods -n kube-system -l app=vlan-config-controller` — the lock is stuck.

**Cause (fixed as of the current `07-vlan-config-controller-scripts.sh`):** the leader lock previously had no etcd lease/TTL attached to it — it was just a plain key, so nothing would ever expire it automatically. If the holder ever crashed or was killed before reaching `release_lock()`, the key was left behind forever. This could genuinely happen because the script ran under `set -e` with the per-job processing loop piped into a subshell (`... | while read; do process_job; done`) — a single unguarded `linode-cli`/`curl` failure inside `process_job()` could kill the entire controller process outright, mid-job, without ever releasing the lock. Worse, a failed `acquire_lock()` call was handled with a silent `sleep 3; continue` — no log line at all — so both replicas would then loop forever in total silence while real, pending jobs sat completely untouched.

The current script fixes this with an etcd lease (`LOCK_LEASE_TTL=30` seconds, refreshed by a background keepalive every `LOCK_KEEPALIVE_INTERVAL=10` seconds) attached to the lock key, so if the holder ever dies without releasing it cleanly, the lease simply expires within 30 seconds and the other replica can take over. The `set -e` was also removed from the main loop, and the per-job read loop uses process substitution instead of a pipe, so one bad job can no longer take down the whole controller process.

**Resolution — immediate unstick** (only needed on older deployments; current deployments self-heal via the lease TTL within ~30 seconds on their own):
```bash
kubectl exec -n kube-system deploy/vlan-config-controller -- sh -c \
  'export ETCDCTL_API=3; etcdctl --endpoints=http://etcd-0.etcd.kube-system.svc.cluster.local:2379 del /vlan-config-controller/leader'
```

**Resolution — permanent fix:** confirm the `vlan-manager-scripts` ConfigMap actually reflects the current, lease-backed version of the script:
```bash
kubectl -n kube-system get cm vlan-manager-scripts -o jsonpath='{.data.07-vlan-config-controller-scripts\.sh}' | grep -n "LOCK_LEASE_TTL"
```
If that comes back empty, the ConfigMap is stale (usually from a manual edit that didn't get re-synced). Refresh it from the repo and restart the controller:
```bash
cd manifests
kubectl -n kube-system delete cm vlan-manager-scripts --ignore-not-found
kubectl -n kube-system create cm vlan-manager-scripts --from-file=../scripts
kubectl rollout restart deployment/vlan-config-controller -n kube-system
```

---

## 3. VLAN IP Controller (REST API) pod not starting

**Diagnosis:**
```bash
kubectl logs -f deployment/vlan-ip-controller -n kube-system
```
(Flask/Werkzeug output goes straight to the container's own stdout now, so `kubectl logs` shows everything, including startup errors and crashes - no need to `exec` into the pod to read a redirected log file. See entry 14 if this predates that fix.)

**Possible causes:**
- Missing or incorrect `linode-cli` configuration (`LINODE_CLI_CONFIG` / `LINODE_API_KEY` not set correctly in the `vlan-manager-secrets` Secret — see [Secrets vs ConfigMap](DEPLOYMENT.md#secrets-vs-configmap)).
- `REGION` or `ETCD_ENDPOINTS` environment variable missing or empty — check with `kubectl exec -n kube-system deploy/vlan-ip-controller -- env`.
- The readiness probe (`GET /health`) failing because Linode's API or etcd isn't reachable from the pod.

**Resolution:** ensure `linode-cli` is configured correctly, and confirm `/health` succeeds directly:
```bash
linode-cli configure
kubectl exec -n kube-system deploy/vlan-ip-controller -- curl -s http://localhost:8080/health
```

---

## 4. VLAN Manager DaemonSet pods not ready

**Diagnosis:**
```bash
kubectl logs -f daemonset/vlan-manager -n kube-system
```

**Possible causes:**
- Network interfaces not configured yet (normal during an active attach cycle — check whether the pod's log shows it's actively progressing, not stuck).
- Routes not pushed successfully.
- `/allocate` calls to `vlan-ip-controller` failing (see entries 5 and 6 below) — the DaemonSet's retry loop only allows 5 attempts, so a slow or erroring controller surfaces here as `"IP allocation failed after 5 attempts"`.

**Resolution:** re-run `00-Orchestration-Script.sh` and monitor logs; if the underlying cause is `vlan-ip-controller` itself, fix that first (entries 3/5/6) and the DaemonSet will recover on its own on the next retry.

---

## 5. IP allocation failing / `/allocate` returns 500 Internal Server Error

**Diagnosis:**
```bash
kubectl logs -n kube-system -l app=vlan-ip-controller --tail=100
```

**Possible causes:**
- The IP range in the configured `SUBNET` is exhausted.
- `vlan-ip-controller` pods aren't `Ready` (see entry 3).
- A malformed Linode API response — e.g. `"data": null` or `"interfaces": null` on a particular instance/config, rather than an empty list. `scripts/06-rest-api.py`'s `fetch_assigned_ips()` guards against this with `.get(...) or []` fallbacks. If you see `'NoneType' object is not iterable` in the logs, the ConfigMap is likely stale and doesn't reflect this fix:
    ```bash
    kubectl -n kube-system get cm vlan-manager-scripts -o jsonpath='{.data.06-rest-api\.py}' | grep -n 'config_view.get("interfaces")'
    ```
    If that doesn't match the repo's current script, re-create the ConfigMap and restart the deployment:
    ```bash
    cd manifests
    kubectl -n kube-system delete cm vlan-manager-scripts --ignore-not-found
    kubectl -n kube-system create cm vlan-manager-scripts --from-file=../scripts
    kubectl rollout restart deployment/vlan-ip-controller -n kube-system
    ```

**Resolution — query what's actually allocated:** there is no `/mnt/vlan-ip/vlan-ip-list.txt` file anymore — the source of truth is etcd, exposed through the controller's own API:
```bash
kubectl exec -n kube-system deploy/vlan-ip-controller -- curl -s http://localhost:8080/api/v1/vlan-ips
```

---

## 6. `/allocate` is very slow on the first call (takes 1–3+ minutes)

**Symptom:** the very first `/allocate` request (or the first one after the cache expires) takes noticeably longer than subsequent ones — sometimes minutes on larger accounts.

**Cause: this is expected behavior, not a bug**, for accounts with many Linode instances. `fetch_assigned_ips()` does a full, serial scan (2 sequential API calls per instance) of every Linode in the region before it can compute which VLAN IPs are already in use. With caching disabled, every single node's onboarding request re-triggers this full scan from scratch.

**Resolution:** set `CACHE_TTL_SECONDS` in `manifests/00-vlan-manager-configmap.yaml` (default `"30"`) so repeated `/allocate` calls within that window reuse one recent scan instead of each re-scanning independently:
```bash
kubectl apply -f 00-vlan-manager-configmap.yaml
kubectl rollout restart deployment/vlan-ip-controller -n kube-system
```
This does **not** introduce a duplicate-IP risk — the actual allocation guard is an atomic etcd compare-and-swap on `/vlan/ip/<ip>`, entirely independent of this cache. The cache only affects how often the (slow) full account scan runs, not correctness.

If `curl` appears to hang with no response at all, tail the pod's logs live during the request to confirm it's actively progressing through instances (look for `[DEBUG] Found VLAN IP from Linode: ...` lines) rather than genuinely stuck:
```bash
kubectl logs -f -n kube-system <vlan-ip-controller-pod>
```
If the log goes completely silent mid-scan with no new lines, that's a real hang worth investigating separately (e.g. an unresponsive etcd endpoint, or a Linode API call with no timeout).

**Related, now fixed:** `app.run(...)` previously had no `threaded=True`, so Werkzeug's dev server could only handle one request at a time - a slow `/allocate` scan on a cold cache blocked the concurrent `/health` probe long enough to trip liveness/readiness failures and get the pod killed by kubelet, turning this documented-as-benign slow-first-call behavior into an actual crash loop under real load (e.g. several nodes onboarding at once against a fresh cluster). See entry 14 below.

---

## 7. etcd / `vlan-config-controller` / CoreDNS pods stuck `Pending`

**Diagnosis:**
```bash
kubectl describe pod <pod-name> -n kube-system
```
Look for `0/N nodes are available: node(s) didn't match Pod's node affinity/selector`.

**Cause:** these components are pinned via `nodeSelector: infra-pool: "true"` (see `manifests/08-etcd-StatefulSet-3node.yaml` and `manifests/10-vlan-config-controller.yaml`), but no node in the cluster currently carries that label/taint.

**Resolution:** create the dedicated `infra-pool` node pool (minimum 3 nodes — required by etcd's pod anti-affinity) with label `infra-pool=true` and taint `infra-pool=true:NoSchedule` *before* running the orchestration script. See [DEPLOYMENT.md](DEPLOYMENT.md#why-a-dedicated-infra-pool-node-pool) for the full rationale and exact steps. If the pool already exists but pods are still `Pending`, double-check the label actually landed:
```bash
kubectl get nodes --show-labels | grep infra-pool
```

---

## 8. A node hosting etcd/CoreDNS/`vlan-config-controller` keeps getting shut down for VLAN attachment

**Cause:** these components aren't isolated on the dedicated `infra-pool` yet, so Kubernetes' default scheduler placed them on a regular node that `vlan-manager` later cycles for VLAN attachment, same as any other node. The `serialized_shutdown` lock/quorum-check logic in `scripts/02-script-vlan-attach.sh` exists specifically to prevent this from breaking the cluster outright — it refuses to shut a node down if doing so would break etcd quorum, and serializes critical-node reboots one at a time rather than letting multiple happen concurrently. But this is a safety net, not something to rely on routinely: it adds real deployment latency (each critical-node reboot involves an atomic etcd lock acquisition, a 30-second replication wait, and a 15-second stabilization wait before the shutdown even starts), and it doesn't eliminate the underlying risk, just slows it down enough to reduce the odds of a bad outcome.

**Resolution:** apply the `infra-pool` isolation described in [DEPLOYMENT.md](DEPLOYMENT.md#why-a-dedicated-infra-pool-node-pool) — pin etcd and `vlan-config-controller` via `nodeSelector`/`tolerations` (already the default in the manifests) and manually patch CoreDNS the same way, onto nodes `vlan-manager` never touches.

---

## 9. PersistentVolumeClaim (PVC) not available / initializer job hangs

**Diagnosis:**
```bash
kubectl describe pvc vlan-ip-pvc -n kube-system
kubectl describe job vlan-ip-initializer -n kube-system
kubectl logs job/vlan-ip-initializer -n kube-system
```

**Cause — known gap:** as of the current manifests, `manifests/05-vlan-ip-initializer-job.yaml` does not actually mount the PVC defined in `manifests/02-vlan-ip-pvc.yaml` into the initializer Job. The job's script writes to `/mnt/vlan-ip/`, which won't exist as a real, persistent mount without a volume mount in the Job spec. If the initializer Job fails, or the orchestration script appears to hang for roughly 10 minutes at `"Waiting for Initializer Job to complete"` (its `kubectl wait` timeout is 600 seconds), this is very likely why.

**Resolution:** this is a genuine code gap, not something resolvable purely through configuration — either add the missing volume mount to the Job spec, or remove the initializer/PVC's dependency on persistent storage if it isn't actually needed (the job's real output, the discovered IP list, ends up synced into etcd regardless — see [DEPLOYMENT.md](DEPLOYMENT.md#components) for `vlan-ip-controller`). Ask if you want this fixed.

---

## 10. VPN tunnel connectivity issues

**Diagnosis:**
```bash
ip route show | grep <DEST_SUBNET>
```

**Resolution:** verify the VPN tunnel configuration and routing policies on both ends. A route existing in `ip route show` only confirms the *local* node knows where to send traffic — it doesn't confirm the remote end is answering. Some things that look like failures here are actually expected and benign:
- A VPN gateway not responding to `ping` on its own VLAN IP is common — many gateway appliances filter ICMP to themselves while still routing transit traffic correctly.
- `traceroute` showing `* * *` for hops after the first is also normal — intermediate devices frequently drop/ignore the TTL-expired ICMP responses `traceroute` depends on, without that indicating a routing problem.
- To get a genuine end-to-end confirmation, use a TCP-based `traceroute` against a real port the destination is listening on (`traceroute -T -p 443 <destination-ip>`) and check that the *final* hop is the actual destination responding — combined with the TTL of a successful `ping` to that same destination (each hop decrements TTL by 1 from the sender's starting value, so you can cross-check the hop count against `traceroute`'s output).

---

## 11. `ENABLE_FIREWALL` on LKE Enterprise (Cilium) clusters

**Background:** `create_and_attach_firewall()` in `scripts/02-script-vlan-attach.sh` hardcodes Calico-specific inbound allow rules (BGP TCP `179`, Typha TCP `5473`, IPIP/`IPENCAP` protocol) alongside generic Kubernetes ports (kubelet health, DNS, NodeBalancer ranges). The firewall's `inbound_policy` is `DROP`, so only what's explicitly listed gets through. This ruleset matches Standard LKE's typical Calico CNI, but LKE Enterprise clusters seen in this project run Cilium instead, which uses entirely different traffic (VXLAN/Geneve UDP encapsulation, its own health-check ports) — none of which are in this allow-list. Enabling this custom firewall on a Cilium cluster could silently block legitimate cross-node CNI traffic.

**Resolution — fixed:** `create_and_attach_firewall()` now checks `LKE_CLUSTER_TYPE` first and unconditionally skips creating/attaching this custom firewall on Enterprise clusters, **regardless of what `ENABLE_FIREWALL` is set to.** This is deliberate, not a bug: LKE Enterprise clusters come with their own managed firewall by default, and this function's Calico-oriented rules would be redundant at best and could conflict with real Cilium traffic at worst. You'll see this logged explicitly (`"LKE Enterprise detected - skipping custom firewall creation regardless of ENABLE_FIREWALL..."`) rather than it silently doing nothing.

On Standard LKE, `ENABLE_FIREWALL` still behaves exactly as documented — it creates/attaches the Calico-oriented firewall when set to `"true"`.

If you specifically need a custom Linode Cloud Firewall in addition to LKE-E's managed one, the override in `create_and_attach_firewall()` would need to be relaxed, and the inbound rules would need Cilium-appropriate ports added first — don't just remove the override without also fixing the ruleset, or you risk blocking real CNI traffic.

---

## 12. Autoscaled nodes take a long time to become usable, and jobs sit `failed` with no automatic retry

**Symptom:** during a cluster-autoscaler scale-up burst, new nodes join the cluster but stay unusable to customer workloads for a long time — Kyverno's `linode-lke-vlan-gating` policy requires `vlan-ready=true` on every application pod, and `mark_node_vlan_ready()` doesn't set that label until VLAN/VPC attachment finishes for that node. (The `vlan-not-ready` taint itself is permanent and unrelated to this timing — it's not what's newly blocking anything here.)

**Cause (fixed as of the current `07-vlan-config-controller-scripts.sh`):** the controller previously processed one pending job at a time, in a single serial loop, with no timeout on the "wait for Linode to report `offline`" and "wait for Linode to report `running`" polling loops. During a burst of N simultaneous new nodes, the Nth node's VLAN attach couldn't even start until the N-1 nodes ahead of it had fully finished their own shutdown/reconfigure/boot cycle — and if any single node's cycle ever got stuck (see entry 8 / the `shutting_down`-stuck-instance case), every node queued behind it stalled indefinitely too, since the loop was blocked waiting on that one job forever.

**Resolution — fixed:** the controller now processes up to `MAX_CONCURRENT_JOBS` (default `5`, ConfigMap-tunable) pending jobs at once instead of one at a time, and each of the two wait loops gives up after `JOB_WAIT_TIMEOUT_SECONDS` (default `300`, ConfigMap-tunable) rather than waiting forever.

**What happens when a job times out:** its etcd entry is marked `status: "failed"`, with `failure_reason` (e.g. `"timeout waiting for offline"` or `"timeout waiting for running (config already applied, boot already triggered)"`) and `failed_at` fields added. The controller does **not** automatically retry a failed job — but in practice this still self-heals in the common case: the `vlan-manager` DaemonSet pod on that node resubmits a fresh `"pending"` job on its own the next time its container restarts and finds VLAN still not attached (`configure_interfaces()` unconditionally overwrites whatever job entry is already there). A job that keeps failing repeatedly means the underlying Linode instance genuinely needs manual investigation (same diagnosis steps as entry 8), not a longer timeout.

**Diagnosis — find failed jobs:**
```bash
kubectl exec -n kube-system deploy/vlan-config-controller -- sh -c \
  'export ETCDCTL_API=3; etcdctl --endpoints=http://etcd-0.etcd.kube-system.svc.cluster.local:2379 get /vlan-config/ --prefix' \
  | grep -B1 '"status":"failed"'
```
The `failed` IP allocation isn't stuck forever either — since a failed job stops counting as "in-flight" once it's no longer `pending`/`processing`, `scripts/11-vlan-ip-reconciler.sh` will eventually reclaim its VLAN IP back to the pool through its normal two-sighting confirmation process (see [DEPLOYMENT.md](DEPLOYMENT.md#vlan-ip-pool-reconciliation)) if the node never comes back on its own.

**Related, separate fix in the same change:** `scripts/02-script-vlan-attach.sh` now annotates a node `cluster-autoscaler.kubernetes.io/scale-down-disabled=true` as soon as it starts (before we even know if VLAN is attached yet), and clears the annotation once `mark_node_vlan_ready()` runs. This closes a related gap: a node still mid-onboarding has no workload pods yet (the `vlan-not-ready` taint is blocking them), which cluster-autoscaler's idle-node detection can misread as "this node is idle, scale it down" — potentially culling a node that's already partway through (or about to start) its VLAN attach, wasting the whole onboarding cost and making the next scale-up attempt start from zero again.

---

## 13. Kyverno's own pods stuck `Pending` after install

**Symptom:** right after `install_kyverno()` runs (Step 7 of `00-Orchestration-Script.sh`), `kubectl get pods -n kyverno` shows all 4 Deployments (`kyverno-admission-controller`, `kyverno-background-controller`, `kyverno-cleanup-controller`, `kyverno-reports-controller`) stuck `0/1 Pending`, and the script itself hangs at `Waiting for deployment "kyverno-admission-controller" rollout to finish: 0 of 1 updated replicas are available...`.

**Diagnosis:**
```bash
kubectl describe deployment kyverno-admission-controller -n kyverno
```
Look for `Node-Selectors: kubernetes.io/os=linux` and `Tolerations: <none>` in the pod template, and, on the actual Pod, a scheduling event like `0/N nodes are available: N node(s) had untolerated taint {vlan-not-ready: true}, N node(s) had untolerated taint {infra-pool: true}`.

**Cause:** Kyverno's upstream install manifest ships with zero tolerations and no `nodeSelector` — it assumes it can schedule anywhere. On this project's clusters, both node pools carry a custom taint (`infra-pool` on `infra-pool`, the permanent `vlan-not-ready` on the app pool), so with no patch, Kyverno has no node anywhere in the cluster it's allowed to land on.

**Resolution — fixed as of the current `00-Orchestration-Script.sh`:** `install_kyverno()` now patches all 4 Kyverno Deployments immediately after install, pinning them to `infra-pool` (`nodeSelector: infra-pool: "true"` plus a toleration for that taint) — the same place etcd/`vlan-config-controller`/CoreDNS already run. If you installed Kyverno manually outside the script (or are running an older version of it), apply the same patch by hand:
```bash
for d in kyverno-admission-controller kyverno-background-controller kyverno-cleanup-controller kyverno-reports-controller; do
  kubectl patch deployment "$d" -n kyverno --type strategic -p '{
    "spec": {"template": {"spec": {
      "nodeSelector": {"infra-pool": "true"},
      "tolerations": [{"key": "infra-pool", "operator": "Equal", "value": "true", "effect": "NoSchedule"}]
    }}}
  }'
done
```

**Related, separate issue you may hit at the same install step:** `kubectl create -f <kyverno-install-url>` can time out with `failed to download openapi: ... dial tcp ...:6443: connect: operation timed out` — this is `kubectl`'s client-side OpenAPI schema fetch (triggered because the install manifest is a large, remote, multi-CRD bundle) timing out independently of whether the cluster itself is healthy. Fixed the same way: the current script passes `--validate=false` to skip that fetch (server-side validation still happens) and retries a few times. If you see this on an older script version, either update it or re-run the `kubectl create` command by hand with `--validate=false` added.

---

## 14. `vlan-ip-controller` pods crash-looping under load (`CrashLoopBackOff`, liveness `EOF`)

**Symptom:** `kubectl get pods -n kube-system -l app=vlan-ip-controller` shows pods cycling through `Running` → `CrashLoopBackOff`, restart counts climbing, `READY 0/1`. Events show `Unhealthy: Liveness probe failed: Get "http://<pod-ip>:8080/health": EOF`. The pod that gets killed usually shows a clean `Exit Code: 0` (not OOMKilled, not a Python traceback) - kubelet's SIGTERM after repeated liveness failures, caught gracefully by the process. Most likely to show up on a fresh cluster with several nodes onboarding (requesting VLAN IPs) around the same time.

**Diagnosis:** `kubectl logs` on this pod alone won't show much (see the logging note below) - check `kubectl describe pod` for the `Unhealthy`/`Killing` events, and correlate timing against `/allocate` activity in the logs of whichever replica was actually handling requests.

**Cause (fixed as of the current `06-rest-api.py`):** Flask's `app.run(...)` had no `threaded=True`, so Werkzeug's built-in dev server processed exactly one request at a time. `/allocate` can legitimately block for 1-3+ minutes on a cold cache (see entry 6 - a full serial scan of every Linode instance in the region), and while it's blocked, the *same process* can't concurrently answer the `/health` probe - the probe request just sits until it times out. Three consecutive failures (the default `#failure=3` on both probes) gets the pod killed. With 3 replicas each keeping their own independent, initially-cold cache, and several nodes all requesting IPs at once on a fresh cluster, this was close to guaranteed to happen rather than a rare edge case.

**Resolution — fixed:** `app.run(host="0.0.0.0", port=8080, debug=False, threaded=True)` lets Werkzeug handle each request on its own thread, so a slow `/allocate` no longer blocks `/health`. This does **not** introduce a duplicate-IP risk - the actual allocation guard is an atomic etcd compare-and-swap transaction in `allocate_ip()`, not anything that depended on requests being serialized. That transaction already had to be race-safe across this app's 3 separate replicas (which share no memory at all), so one more thread within a single process doesn't change what etcd was already arbitrating.

**Related fix, same change - container logs were invisible:** the container command used to redirect the whole process's stdout/stderr into `/tmp/flask.log` *inside* the container (`exec python3 ... > /tmp/flask.log 2>&1`), so `kubectl logs` only ever showed the shell's `echo`/`cp` lines from before that redirect took effect - nothing from Flask/Werkzeug itself, including any crash output, was visible via `kubectl logs`. Diagnosing this issue originally required `kubectl exec <pod> -- cat /tmp/flask.log` while the pod happened to still be alive, racing the next restart. Fixed by removing the redirect entirely (`manifests/06-vlan-ip-controller-deployment.yaml` and the `post-migration/` copy) - Flask's output now goes straight to the container's own stdout/stderr, so `kubectl logs -n kube-system <pod>` shows it directly, including on crash. The app's own structured allocation log (`log()` in `06-rest-api.py`) is unaffected - it separately writes to `/tmp/allocate-ip.log` regardless of this change.

---

## 15. Cluster-wide deadlock: no node ever becomes `Ready` (LKE Enterprise/Cilium), or several LKE system Deployments sit `Pending` forever (LKE Standard/Calico)

**Symptom (Enterprise):** every node stays `NotReady` indefinitely, `kubectl get pods -n kube-system -l k8s-app=cilium` shows every Cilium agent in `CrashLoopBackOff`, and their logs repeat `"Still waiting for Cilium Operator to register CRDs"` forever. `kubectl get pods -n kube-system -l io.cilium/app=operator` shows `cilium-operator` itself stuck `Pending` with **zero** nodes ever available to it. This is a full cluster deadlock, not a partial degradation - CNI never comes up, so no node can ever satisfy kubelet's Ready condition, so `cilium-operator` (a plain Deployment, not a DaemonSet) can never find a schedulable node either.

**Symptom (Standard):** less severe but the same root cause - `calico-kube-controllers`, `calico-typha-autoscaler`, `coredns`/`workload-coredns`, `coredns-autoscaler`, `konnectivity-agent`, `konnectivity-autoscaler`, and the `csi-linode-controller` StatefulSet can all sit `Pending` indefinitely. Nodes themselves still reach `Ready` (Calico's own per-node agent is a DaemonSet with its own implicit taint tolerances), but cluster DNS, the CSI provisioner (so PVCs never bind - directly blocks etcd), and Calico's controller/autoscaler don't come up.

**Diagnosis:**
```bash
kubectl describe pod -n kube-system -l io.cilium/app=operator   # Enterprise
kubectl get pods -n kube-system -o wide | grep -v Running        # either type
```
Look for `0/N nodes are available: N node(s) had untolerated taint {infra-pool: true}, N node(s) had untolerated taint {vlan-not-ready: true}` in the Pending pod's events.

**Cause:** these are all LKE-managed `kube-system` workloads that ship with **no tolerations of their own** - their upstream manifests assume they can schedule anywhere. This project's own workloads carry explicit tolerations (see `manifests/07-vlan-manager-daemonset.yaml`'s header comment), and `install_kyverno()` already patched Kyverno's own 4 Deployments for the same reason - but until this fix, nothing patched *these* LKE-shipped ones. The moment both node pools carry a custom taint from day one (this project's own documented default setup - see [Why a dedicated infra-pool node pool](DEPLOYMENT.md#why-a-dedicated-infra-pool-node-pool)), every node in the cluster is tainted and none of these have anywhere left to schedule. Confirmed by reproducing the full deadlock end-to-end on a fresh LKE Enterprise cluster, and the Standard-side Pending pods on a fresh LKE Standard cluster, in the same session.

**Resolution — fixed:** `auto_pin_lke_system_components()` in `00-Orchestration-script.sh` now pins all of these (whichever actually exist on this cluster type - each is checked defensively, not cluster-type-branched) to `infra-pool`, the same nodeSelector+toleration pattern as `auto_pin_coredns()`/Kyverno, called automatically right after `ensure_infra_pool()` succeeds on every deploy. If you're on an older version of this script or patched a cluster manually before this fix existed, apply the same pattern by hand:
```bash
PATCH='{"spec":{"template":{"spec":{"nodeSelector":{"infra-pool":"true"},"tolerations":[{"key":"infra-pool","operator":"Equal","value":"true","effect":"NoSchedule"}]}}}}'
for d in cilium-operator calico-kube-controllers calico-typha-autoscaler coredns-autoscaler konnectivity-agent konnectivity-autoscaler; do
  kubectl get deployment "$d" -n kube-system &>/dev/null && kubectl patch deployment "$d" -n kube-system --type merge -p "$PATCH"
done
kubectl get statefulset csi-linode-controller -n kube-system &>/dev/null && {
  kubectl patch statefulset csi-linode-controller -n kube-system --type merge -p "$PATCH"
  kubectl delete pod -n kube-system -l app=csi-linode-controller  # StatefulSets don't recreate an already-Pending pod on template change alone
}
```
This same set also needs moving *off* `infra-pool` during migration - `post-migration-consolidate.sh`'s Step 5 now does this automatically; see [Migration: Retiring infra-pool](DEPLOYMENT.md#migration-retiring-infra-pool).

---

## 16. `vlan-ip-reconciler` fails every run - scheduled *and* manual - with `ETCD_ENDPOINTS: ETCD_ENDPOINTS not set`

**Symptom:** `kubectl get jobs -n kube-system | grep reconciler` shows every job `Failed`, including ones from the CronJob's own 15-minute schedule (not just manual triggers). `kubectl logs job/vlan-ip-reconciler-<...>` shows exactly one line: `/tmp/reconciler.sh: line 59: ETCD_ENDPOINTS: ETCD_ENDPOINTS not set`. This means the reconciler has **never successfully run once** since deployment - it fails at the same `: "${ETCD_ENDPOINTS:?...}"` guard on line 59 of the script, immediately, every time.

**Diagnosis:**
```bash
kubectl get cronjob vlan-ip-reconciler -n kube-system -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="ETCD_ENDPOINTS")]}'
```
If this prints `{"name":"ETCD_ENDPOINTS"}` with no `"value"` field at all, this is it.

**Cause (fixed as of the current `00-Orchestration-script.sh`):** Step 10 (deploying `11-vlan-ip-reconciler-cronjob.yaml`) called `envsubst '${ETCD_ENDPOINTS}'` without first exporting `ETCD_ENDPOINTS` itself. Every other `envsubst '${ETCD_ENDPOINTS}'` call site in the script is wrapped in its own function that exports the variable right before use and `unset`s it right after (see e.g. `apply_vlan_config_controller()`). Step 10 had no such wrapper - it silently relied on whichever step ran immediately before it having left `ETCD_ENDPOINTS` set, but the immediately-preceding step (`Create_vlan_manager_daemonset`) always `unset`s it right after its own use. The result: `envsubst` substituted an empty string, and the deployed CronJob's `ETCD_ENDPOINTS` env var ended up with no value at all. Confirmed live against a real cluster: both the CronJob's own scheduled run *and* the manual-trigger command this same README documents (`kubectl create job --from=cronjob/vlan-ip-reconciler ...`) failed identically, immediately, every time.

**Resolution — fixed:** Step 10 now exports `ETCD_ENDPOINTS` itself (based on node count, same pattern as every other step) immediately before its own `envsubst` call, and `unset`s it after. If you deployed with an older script version, re-run `00-Orchestration-Script.sh` (idempotent), or fix the live CronJob directly:
```bash
export ETCD_ENDPOINTS="http://etcd-0.etcd.kube-system.svc.cluster.local:2379,http://etcd-1.etcd.kube-system.svc.cluster.local:2379,http://etcd-2.etcd.kube-system.svc.cluster.local:2379"  # or the 1-endpoint form on a <3-node cluster
cd manifests
envsubst '${ETCD_ENDPOINTS}' < 11-vlan-ip-reconciler-cronjob.yaml | kubectl apply -f -
unset ETCD_ENDPOINTS
```

---

## 17. `vlan-ip-reconciler` repeatedly logs the subnet's network/gateway/broadcast address as an "orphan candidate"

**Symptom:** every reconciler run (or every other run, once past first-sighting) logs something like `Releasing confirmed orphaned IP: 10.x.x.0` followed by `-> {"error":"IP address 10.x.x.0 is reserved and cannot be released."}` - for the subnet's network address, its first usable host (the conventional gateway), and its broadcast address. This is **not** a correctness bug - `/release`'s own reserved-address guard (`06-rest-api.py`) always correctly refuses these, so nothing is ever actually released - but it's permanent log noise and a wasted Linode-scan-driven release attempt on every confirmed-candidate run, forever.

**Cause (fixed as of the current `11-vlan-ip-reconciler.sh`):** `05-script-ip-list-initialize.sh` permanently marks a subnet's network/gateway/broadcast addresses as "used" in etcd so `/allocate` can never hand them out - by design, they're never supposed to be released. But they also never show up in a *real* Linode VLAN attachment scan either, since nothing is ever actually attached at those addresses. The reconciler's orphan-candidate computation (etcd-used minus real-Linode-attachments minus in-flight-jobs) had no exclusion for this case, so these three addresses matched "used in etcd, not really attached" on every single run - the exact same shape as a genuine orphan.

**Resolution — fixed:** added `ip_is_reserved()` (mirrors `reserved_set()` in `06-rest-api.py` exactly - network address, broadcast address, first usable host) and excluded matching addresses from `ETCD_USED_IPS` before candidate computation, so they never enter the orphan-detection logic at all. If you're on an older script version, this is harmless to leave as-is (nothing is ever actually released) but noisy - update to pick up the fix.

---

## 18. LKE Enterprise cluster unreachable after creation (`TLS handshake timeout` / `context deadline exceeded`, every retry)

**Symptom:** `kubectl` against a freshly-created LKE Enterprise cluster's kubeconfig fails every single request with `net/http: TLS handshake timeout` or `context deadline exceeded`, persisting for many minutes - long past any reasonable control-plane bootstrap time. Worker nodes may show as `ready` at the Linode API level (`linode-cli lke pools-list`) the whole time; this is purely an API-reachability problem, not a provisioning-in-progress one.

**Diagnosis:**
```bash
linode-cli lke cluster-acl-view <cluster-id> --json
```
If this shows `"acl": {"enabled": true, "addresses": {"ipv4": [], "ipv6": []}}}` - an empty allowlist with the ACL enabled - that's it: **every** client, including yours, is blocked.

**Cause:** this is genuinely an LKE Enterprise platform default, not a bug in this repo - Enterprise clusters' control plane ACL defaults to `enabled: true` with nothing in the allowlist, unlike Standard clusters. Not something `00-Orchestration-script.sh` currently manages or warns about.

**Resolution:**
```bash
linode-cli lke cluster-acl-update <cluster-id> --acl.enabled true --acl.addresses.ipv4 <your-public-ip>/32
```
Allow a few minutes for the ACL change to propagate before retrying `kubectl` - it does not take effect instantly. Add every IP that needs access (CI runners, other operators' machines), not just your own.

---

## 19. Re-running `00-Orchestration-script.sh` against an already-working deployment tears everything down after an unrelated, transient failure

**Symptom:** you re-run `00-Orchestration-script.sh` against a cluster that already has a healthy deployment on it (e.g. to pick up a config change or a script edit), the script fails partway through on something unrelated and often transient - the confirmed case was `vlan-ip-controller`'s `/health` check reporting failure - and the script's `EXIT` trap then tears down **everything** it manages: etcd and its PVCs, both controllers, the Kyverno policy, every ConfigMap/Secret. A deployment that was working before the re-run is gone afterward, even though the thing that actually failed had nothing to do with most of what got deleted.

**Root cause (two compounding bugs, both fixed on `dev`):**
1. The health-check retry loop selected `LEADER_POD` **once**, outside the retry loop, with no `--field-selector=status.phase=Running` filter. During a rolling update this could select a pod that was already `Terminating` - `kubectl exec`/`curl` against it fails even though the *replacement* pod's `/health` was returning `200` the whole time. A real rollout-timing race produced a false-negative failure.
2. The `EXIT` trap called `cleanup()` unconditionally on any non-success exit, with no concept of whether the run was a first-time deploy (nothing of value exists yet, safe to tear down) or a re-run against an already-working cluster (tearing down destroys real, working state over an unrelated hiccup).

**Fix:**
- `LEADER_POD` is now re-selected **inside** the retry loop on every attempt, filtered with `--field-selector=status.phase=Running`, so a Terminating pod from an in-flight rollout is never targeted.
- A new `is_fresh_deploy()` check (sets `IS_FRESH_DEPLOY`) runs at the start of the script, checking whether `etcd`/`vlan-config-controller`/`vlan-ip-controller`/`vlan-manager` already exist. The raw `cleanup()` function itself stays unconditional (so the explicit `--cleanup` flag still always does a full teardown on request, regardless of what exists). A new `cleanup_on_unexpected_failure()` wrapper - now what the `EXIT` trap actually calls - only invokes `cleanup()` when **both** `DEPLOYMENT_SUCCESS` is not `"true"` **and** `IS_FRESH_DEPLOY` is `"true"`. A failed re-run against an existing deployment now just prints the error and leaves the cluster alone instead of tearing it down; a failed genuinely-first-time deploy still cleans up after itself as before.

**If you hit this on an older checkout:** pull `dev`, or manually check `trap` near the bottom of `00-Orchestration-script.sh` - it must read `trap cleanup_on_unexpected_failure EXIT`, not `trap cleanup EXIT`. Regression coverage for both halves of this fix (the gated wrapper vs. the unconditional `--cleanup` path) is in `tests/static/test_orchestration_script_safety.py`.

**If it already happened to you:** the node pools, VLAN interfaces, and etcd's underlying PersistentVolumes are not touched by `cleanup()`'s Kubernetes-level teardown as long as the PV `reclaimPolicy` is `Retain` (the default in this repo's StatefulSet manifest) - a deleted PVC leaves its PV in a `Released` state with data intact, recoverable by re-binding rather than re-provisioning from scratch. Re-running `00-Orchestration-script.sh` performs a fresh deploy against the surviving node pools; it does not automatically rebind a `Released` PV, so check `kubectl get pv` before assuming a clean re-deploy will just work if etcd data continuity matters to you.

---

## 20. Re-running `00-Orchestration-script.sh` fails with `The Job "vlan-ip-initializer" is invalid: spec.template: ... field is immutable`

**Symptom:** re-running `00-Orchestration-script.sh` against an already-deployed cluster prints a large JSON error ending in `field is immutable`, right around "Launching VLAN IP Initializer Job...". The script doesn't stop - it goes on to report `Initializer Job found` and `condition met` a moment later, and finishes with no other errors, making this easy to miss entirely.

**Cause:** a Kubernetes `Job`'s pod template (`spec.template`) cannot be changed after creation - unlike a Deployment/DaemonSet/StatefulSet, `kubectl apply` can never update an existing Job in place; the API server rejects the whole apply outright. `Apply_Initializer_Job()` used to `kubectl apply` the initializer Job unconditionally, with no check on the result. Every prior re-run happened to apply a byte-identical spec (a no-op as far as the API server's concerned), so this never surfaced - until this Job's spec actually changed between two runs on the same cluster for the first time (e.g. after adding the `LOG_LEVEL` env var). The apply's failure went unchecked, so the script proceeded to `kubectl wait`/report success against the **old, already-completed** Job instead of a fresh one - silently skipping the IP re-sync that run was supposed to do, with no visible failure.

**Fixed on `dev`:** `Apply_Initializer_Job()` now runs `kubectl delete job vlan-ip-initializer -n kube-system --ignore-not-found --wait=true` before every apply, guaranteeing a genuinely fresh Job (and a fresh run of `05-script-ip-list-initialize.sh`) every time, regardless of whether the spec actually changed.

**If you're on an older checkout:** `kubectl delete job vlan-ip-initializer -n kube-system --ignore-not-found` before re-running the script, or just pull `dev`.

---

## 21. LKE Standard: app-pool nodes never reach `vlan-ready=true` - `vlan-manager` keeps retrying the same node forever, and the node's `AGE` keeps resetting

**Symptom:** on an LKE **Standard** cluster specifically (not confirmed on Enterprise), app-pool nodes never pick up the `vlan-ready=true` label no matter how long you wait. `kubectl get nodes` shows the affected node's `AGE` is suspiciously low relative to when the cluster was actually created, and it keeps getting even lower across repeated checks - as if the node keeps restarting from scratch.

**Root cause (confirmed via Linode's own account event log, not a guess):** `linode-cli events list --json` shows, for the affected node, a repeating sequence of `linode_shutdown` -> **`linode_delete` -> `linode_create`** -> `disk_create` -> `linode_boot` - not a plain reboot. LKE Standard's own node-pool management is rebuilding the node from scratch (a full delete+recreate from the pool template, wiping any interface config just written to it) rather than just power-cycling it. The trigger appears to be **how long the node sits offline**: `serialized_shutdown()` in `02-script-vlan-attach.sh` had an unconditional `sleep 30` "to allow etcd leader stabilization" before every shutdown call, including on non-critical app-pool nodes that have no etcd on them at all - stacked with `vlan-config-controller`'s own offline-detection polling in `process_job()` afterward, and the instance's own real shutdown time, the total offline window was long enough to trip whatever internal threshold LKE Standard uses to decide a node has failed and needs rebuilding. A fast manual shutdown -> reconfigure -> reboot cycle (confirmed live, well under a minute total) on the same cluster did **not** trigger a rebuild - only the automation's slower cycle did. Each LKE-triggered rebuild produces a brand-new instance with zero custom interfaces, so `vlan-manager`'s next DaemonSet pod (fresh, since the node itself is fresh) sees VLAN still missing and tries again - an unbounded retry loop that never converges, confirmed live: 4 rebuild cycles in ~35 minutes on cluster 648300 before testing was paused.

**Fixed on `dev`:** the 30s sleep is now conditional on `IS_CRITICAL` - only critical nodes (hosting etcd/CoreDNS/`vlan-config-controller`) pay it; non-critical app-pool nodes shut down without the extra delay.

**Status: confirmed fixed, live-verified.** Both app-pool nodes on a real LKE Standard cluster reached `vlan-ready=true` with the clean `shutdown -> config_update -> boot` pattern and zero `linode_delete` events, on two separate clusters (one re-tested in place, one a fresh cluster created after this fix landed). If you hit this and the fix above doesn't fully resolve it for your account/region, the next thing to try is eliminating the separate "wait for offline, then config-update, then boot" round trip entirely in favor of updating the config while the instance is still running (Linode's API accepts a config update regardless of power state - only *applying* it requires a reboot) followed by a single `linode-cli linodes reboot` call, which is closer to what a human doing this by hand in Cloud Manager naturally does. That's a bigger change (touches the critical-node lock/quorum coordination too) and wasn't needed here - see git history/session notes before attempting it.

---

## 22. `vlan-ip-controller` pods explode into 100+ `Failed`/`ContainerStatusUnknown` objects during a fresh cluster's initial VLAN/VPC attach

**Symptom:** on a brand-new deploy (or any time multiple app-pool nodes go through VLAN/VPC attach at close to the same moment), `kubectl get pods -n kube-system -l app=vlan-ip-controller` returns well over a hundred pods, nearly all `Failed` or `ContainerStatusUnknown`, alongside the 3 real `Running` ones. The Deployment itself reports healthy (`3/3/3`) throughout - this is entirely garbage pod objects, not an actual outage - but it clutters `kubectl get pods` badly and represents real, if brief, API server load.

**Cause (confirmed live via pod `creationTimestamp`s):** `vlan-ip-controller`'s Deployment used to require `app-pool=true` nodeAffinity - the exact nodes `vlan-manager` shuts down and reboots as part of every VLAN/VPC attach. Nothing in `vlan-manager`'s non-critical (app-pool) shutdown path serializes across nodes - two nodes can and do call `linode-cli linodes shutdown` in the same second. When **every** app-pool node is down simultaneously, `vlan-ip-controller` has zero nodes it's allowed to schedule onto. Kubernetes has no built-in backoff for a ReplicaSet repeatedly failing to *create* new pods (container-level `CrashLoopBackOff` only throttles a container restarting inside an existing pod - these pods never started at all), so the ReplicaSet controller rapid-fired pod creation attempts - dozens within a single second in the confirmed incident - until app-pool nodes came back.

**Fixed on `dev`:** `vlan-ip-controller` is now pinned to `infra-pool` (`06-vlan-ip-controller-deployment.yaml`), the same protection `etcd`/`vlan-config-controller`/CoreDNS already have - infra-pool nodes are never touched by the VLAN/VPC attach cycle, so the zero-eligible-nodes condition can't happen. `post-migration-consolidate.sh` gained a new Step 3 to move it onto `vlan-ready` app-pool nodes once migration is safe, matching the other three components' pattern (see [Migration: Retiring infra-pool](DEPLOYMENT.md#migration-retiring-infra-pool)).

**If you already have a pile of these:** they're harmless garbage, safe to bulk-delete:
```bash
kubectl get pods -n kube-system -l app=vlan-ip-controller --field-selector=status.phase!=Running -o name | xargs kubectl delete -n kube-system
```

**If you're on an older checkout:** pull `dev`, or manually patch the Deployment's `nodeAffinity` from `app-pool: true` to `infra-pool: true` and `kubectl rollout restart deployment/vlan-ip-controller -n kube-system`.

---

## 23. On LKE Standard, `konnectivity-agent-autoscaler` sits `Pending` forever (`0/N nodes are available: N node(s) had untolerated taint(s)`) - and `post-migration-consolidate.sh`'s Step 7 doesn't catch it either

**Symptom:** `kubectl get deployment -n kube-system` shows `konnectivity-agent-autoscaler` (not `konnectivity-autoscaler`) with `0/1` ready, stuck `Pending` indefinitely - `kubectl describe` shows `FailedScheduling: 0/N nodes are available: N node(s) had untolerated taint(s)`. This can sit unnoticed for a long time since nothing else depends on it.

**Cause:** `auto_pin_lke_system_components()` (`00-Orchestration-script.sh`) and `post-migration-consolidate.sh`'s Step 6 both pin a hardcoded list of LKE-managed `kube-system` Deployments to whichever pool needs them, using a `kubectl get deployment <name> || continue` existence guard so the same list safely covers both cluster types. That guard only skips a name that genuinely doesn't exist - it can't detect "this component exists under a *different* name" - and confirmed live, **the konnectivity autoscaler's Deployment name is not consistent across cluster types**: `konnectivity-autoscaler` on LKE Enterprise (matches the hardcoded name, works fine), but `konnectivity-agent-autoscaler` on LKE Standard (doesn't match anything in the list, silently skipped, never pinned to either pool, and therefore has zero tolerations for either pool's permanent taint once one exists).

**Fixed on `dev`:** both lists now include both names explicitly - `konnectivity-autoscaler` **and** `konnectivity-agent-autoscaler` - so whichever one actually exists on a given cluster gets matched and pinned; the other is silently skipped by the same existence guard as always.

**If you already have this stuck:** patch it directly with the same shape the automation would have applied (adjust `infra-pool`/`vlan-ready` depending on whether this cluster has been through `post-migration-consolidate.sh` yet):
```bash
kubectl patch deployment konnectivity-agent-autoscaler -n kube-system --type merge -p \
  '{"spec":{"template":{"spec":{"nodeSelector":{"infra-pool":"true"},"tolerations":[{"key":"infra-pool","operator":"Equal","value":"true","effect":"NoSchedule"}]}}}}'
```

**Related gotcha found in the same live test:** `post-migration-consolidate.sh`'s Step 0 has an interactive `read -r -p "Continue anyway? [y/N]"` prompt for the case where fewer than 3 app-pool nodes are `vlan-ready=true` yet. Run non-interactively (e.g. backgrounded, or piped through `tee` with no TTY attached) with too few ready nodes, the script stops there silently - **and if you piped its output through `tee`, the reported exit code of the whole pipeline reflects `tee` (which always succeeds), not the script**, masking the fact that nothing actually ran. Always check the *log content* for `=== Consolidation complete. ===`, not just the reported exit code, when running this script non-interactively. Scale app-pool to at least 3 `vlan-ready=true` nodes first to avoid the prompt entirely - this is also a real functional requirement (etcd's pod anti-affinity needs 3 distinct nodes), not just a way to dodge the prompt.

---

## 24. A bare/standalone debug pod on an `infra-pool` node isn't flagged by `post-migration-consolidate.sh`'s Step 7 (or `check-infra-pool-safe-to-delete.sh`)

**Symptom:** you manually `kubectl run` a debug pod (or similar bare Pod with no owning controller) directly onto an `infra-pool` node while troubleshooting, forget to delete it, and neither Step 7's final check nor `check-infra-pool-safe-to-delete.sh` ever reports it - both say the pool is empty and safe to delete even though your debug pod is still sitting there.

**Cause:** both checks filtered on `select(any(.metadata.ownerReferences[]?; .kind != "DaemonSet"))` - read as "flag anything with at least one non-DaemonSet owner". `any` over an **empty** array is vacuously false, and a bare pod created directly (not via a Deployment/StatefulSet/Job/DaemonSet) has no `ownerReferences` at all - so it silently matched nothing and was treated the same as an actual DaemonSet pod. Confirmed live by intentionally creating exactly this kind of pod on an `infra-pool` node and watching both checks report "safe" with it still running there.

**Fixed on `dev`:** both now check "does this pod have zero `DaemonSet`-kind owners" (`select([.metadata.ownerReferences[]? | select(.kind == "DaemonSet")] | length == 0)`), which correctly flags a bare pod, a Deployment/StatefulSet/Job-owned pod, *and* still correctly skips a genuine DaemonSet pod. Re-verified live with the same reproduction: the fixed check correctly reported "NOT safe to delete" while the debug pod existed, and "safe" again immediately after deleting it.

**If you're on an older checkout:** don't trust either check blindly - also eyeball `kubectl get pods -A --field-selector spec.nodeName=<infra-pool-node>` yourself before deleting the pool, or pull `dev`.

---

## General debugging commands

Useful starting points for anything not covered by a specific entry above:
```bash
# All pods and their status
kubectl get pods -n kube-system

# Logs for a specific pod
kubectl logs -f pod/<pod-name> -n kube-system

# Full details on a specific pod, including events
kubectl describe pod <pod-name> -n kube-system

# Confirm linode-cli itself is configured and working
linode-cli linodes list
```

---

## Need more help?

If an issue persists after working through the relevant entry above, collect the pod logs and `kubectl describe` output for the affected component and reach out with those attached — see the [README](../README.md#support) for contact details.
