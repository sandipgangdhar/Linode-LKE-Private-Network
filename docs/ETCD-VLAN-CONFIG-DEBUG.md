# etcd VLAN config keys – verification and manual inspection

## Where the DaemonSet writes (02-script-vlan-attach.sh)

- **When:** Only when **VLAN is not attached** and the node needs a VLAN (and optional VPC). Flow:
  1. Script allocates a VLAN IP via the vlan-ip-controller API.
  2. It builds the desired Linode config (interfaces: public, VLAN, optional VPC).
  3. It calls **`configure_interfaces()`** (around line 913), which:
     - Builds `DESIRED_JSON` with `linode_id`, `current_config_id`, `interfaces`, `status: "pending"`.
     - Writes to etcd, then calls **`serialized_shutdown()`** and exits.

- **Key:**  
  `DESIRED_KEY="/vlan-config/${LINODE_ID}"`  
  Example: `/vlan-config/12345678` (LINODE_ID = Linode instance ID from the API).

- **Value (JSON):**  
  ```json
  {
    "linode_id": 12345678,
    "current_config_id": 987654,
    "interfaces": [ { "purpose": "vpc", ... }, { "purpose": "public" }, { "purpose": "vlan", "label": "private-lan", "ipam_address": "192.168.1.10/24" } ],
    "status": "pending"
  }
  ```

- **API used:**  
  `POST ${ETCD_PRIMARY}/v3/kv/put`  
  Body: `{"key": "<base64(DESIRED_KEY)>", "value": "<base64(DESIRED_JSON)>"}`  
  (ETCD_PRIMARY = leader from `get_etcd_leader_endpoint`.)

- **Code location:**  
  In `configure_interfaces()`, roughly lines 1017–1061: build `DESIRED_JSON`, set `DESIRED_KEY`, then `curl` to `.../v3/kv/put`.  
  Call path: main script → “VLAN is not attached” branch → `configure_interfaces()` → etcd put → `serialized_shutdown()`.

So: the DaemonSet writes **only** when it has decided to add VLAN (and optional VPC), has built the desired config, and is about to shut down so the vlan-config-controller can apply it.

---

## How the controller finds jobs without knowing LINODE_ID

The controller **does not** need to know `LINODE_ID` in advance. It uses a **prefix (range) query**:

- **Request:** “Give me all keys in the range `["/vlan-config/", "/vlan-config:")`.” (range_end `/vlan-config:` is > any `/vlan-config/<id>`.)
- **Effect:** etcd returns every key that starts with `/vlan-config/`, e.g.:
  - `/vlan-config/12345678`
  - `/vlan-config/87654321`
- **Response:** For each key, etcd returns the **value** (the JSON with `linode_id`, `current_config_id`, `interfaces`, `status`).

So the controller discovers all jobs by listing the prefix `/vlan-config/`; each key is `/vlan-config/<LINODE_ID>` and the value holds the rest. It then filters for `status == "pending"` and processes those.

---

## Inspecting etcd from the vlan-config-controller pod

The controller pod has `curl`, `jq`, and `base64`. Use any healthy etcd endpoint (e.g. from `ETCD_ENDPOINTS`).

**1. Exec into a running controller pod**

```bash
kubectl exec -it deploy/vlan-config-controller -n kube-system -- bash
```

**2. List all keys under `/vlan-config/` (same range the controller uses)**

Use the endpoint that works from your pod (controller often reaches etcd-1 or etcd-2; etcd-0 may return HTTP 000 from some pods):

```bash
# Try etcd-1 if etcd-0 gives HTTP 000
EP="http://etcd-1.etcd.kube-system.svc.cluster.local:2379"
# Or: EP="http://etcd-2.etcd.kube-system.svc.cluster.local:2379"
KEY=$(echo -n "/vlan-config/" | base64 | tr -d '\n')
# range_end must be > any /vlan-config/<id>; ":" (58) > "9" (57)
RANGE_END=$(echo -n "/vlan-config:" | base64 | tr -d '\n')
curl -s -X POST "$EP/v3/kv/range" \
  -H "Content-Type: application/json" \
  -d "{\"key\":\"$KEY\",\"range_end\":\"$RANGE_END\"}" | jq .
```

**3. Same, but only print key names and decoded value (status)**

```bash
EP="http://etcd-0.etcd.kube-system.svc.cluster.local:2379"
KEY=$(echo -n "/vlan-config/" | base64 | tr -d '\n')
RANGE_END=$(echo -n "/vlan-config:" | base64 | tr -d '\n')
curl -s -X POST "$EP/v3/kv/range" \
  -H "Content-Type: application/json" \
  -d "{\"key\":\"$KEY\",\"range_end\":\"$RANGE_END\"}" | jq -r '.kvs[]? | "key: \(.key | @base64d)\nvalue: \(.value | @base64d)\n---"'
```

**4. Count keys under `/vlan-config/`**

```bash
EP="http://etcd-0.etcd.kube-system.svc.cluster.local:2379"
KEY=$(echo -n "/vlan-config/" | base64 | tr -d '\n')
RANGE_END=$(echo -n "/vlan-config:" | base64 | tr -d '\n')
curl -s -X POST "$EP/v3/kv/range" \
  -H "Content-Type: application/json" \
  -d "{\"key\":\"$KEY\",\"range_end\":\"$RANGE_END\"}" | jq '.count, (.kvs | length)'
```

**5. Optional: try another etcd replica if the first is unreachable**

```bash
for EP in http://etcd-0.etcd.kube-system.svc.cluster.local:2379 http://etcd-1.etcd.kube-system.svc.cluster.local:2379 http://etcd-2.etcd.kube-system.svc.cluster.local:2379; do
  echo "Trying $EP"
  curl -fsS -m 3 -X POST "$EP/v3/kv/range" \
    -H "Content-Type: application/json" \
    -d '{"key":"'$(echo -n "/vlan-config/" | base64 | tr -d '\n')'","range_end":"'$(echo -n "/vlan-config:" | base64 | tr -d '\n')'"}' | jq '.count'
done
```

If **count is always 0** and **kvs is empty**, no job has been written yet. That means the DaemonSet on the node that shut down either never reached `configure_interfaces()` or the etcd put failed (check DaemonSet logs from when the node was still up).

---

## If you see no output from jq

**1. See raw response and HTTP code (no jq):**

```bash
EP="http://etcd-0.etcd.kube-system.svc.cluster.local:2379"
KEY=$(echo -n "/vlan-config/" | base64 | tr -d '\n')
RANGE_END=$(echo -n "/vlan-config:" | base64 | tr -d '\n')
curl -s -w "\nHTTP_CODE:%{http_code}\n" -X POST "$EP/v3/kv/range" \
  -H "Content-Type: application/json" \
  -d "{\"key\":\"$KEY\",\"range_end\":\"$RANGE_END\"}"
```

**2. Test etcd reachability (minimal range request):**

```bash
curl -s -w "\nHTTP:%{http_code}\n" -X POST "http://etcd-0.etcd.kube-system.svc.cluster.local:2379/v3/kv/range" \
  -H "Content-Type: application/json" \
  -d '{"key":"L3ZsYW4tY29uZmlnLw=="}'
```

(L3ZsYW4tY29uZmlnLw== is base64 of "/vlan-config/".) You should see JSON with at least `"header"` and `"count"` (and `"kvs"` array, possibly empty).

---

## List ALL keys in etcd

From the controller pod (use etcd-1; etcd-0 may give HTTP 000):

```bash
EP="http://etcd-1.etcd.kube-system.svc.cluster.local:2379"
# Key and range_end = base64 of null byte => full key space
curl -s -X POST "$EP/v3/kv/range" \
  -H "Content-Type: application/json" \
  -d '{"key":"AA==","range_end":"AA=="}' | jq .
```

To print only key names (decoded):

```bash
EP="http://etcd-1.etcd.kube-system.svc.cluster.local:2379"
curl -s -X POST "$EP/v3/kv/range" \
  -H "Content-Type: application/json" \
  -d '{"key":"AA==","range_end":"AA=="}' | jq -r '.kvs[]? | .key | @base64d'
```

To print key and value (decoded) for each:

```bash
EP="http://etcd-1.etcd.kube-system.svc.cluster.local:2379"
curl -s -X POST "$EP/v3/kv/range" \
  -H "Content-Type: application/json" \
  -d '{"key":"AA==","range_end":"AA=="}' | jq -r '.kvs[]? | "\(.key | @base64d): \(.value | @base64d)"'
```
