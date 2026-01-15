# ======================================================================================
# VLAN IP Controller / IP Allocator (Flask) — Heavily Commented Reference Version
#
# What this service does (high level)
# -----------------------------------
# 1) Exposes a REST API (Flask) used by automation running on LKE worker nodes / VMs:
#      - POST /allocate   -> returns the next available VLAN IP from a given subnet
#      - POST /release    -> releases an IP back to the pool
#      - GET  /health     -> health checks (Linode API + etcd + system)
#      - GET  /api/v1/vlan-ips -> lists IPs currently recorded in etcd
#      - POST /api/v1/refresh  -> triggers a Kubernetes Job to re-sync IP usage from Linode
#      - GET  /api/v1/refresh/<job>/detail -> fetch refresh job status + logs
#
# 2) Uses etcd as the "source of truth" for IP allocation state, and uses Linode API as an
#    external validation source (to detect IPs already in-use by VLAN interfaces).
#
# Why etcd is used
# ----------------
# - Multiple clusters/nodes may request an IP concurrently.
# - etcd provides atomic compare-and-set transactions so only one requester can claim an IP.
#
# Important design notes (to avoid duplicate allocations)
# -------------------------------------------------------
# - **Canonical key format**: this version expects keys like /vlan/ip/<BARE_IP> (no CIDR).
#   Example: /vlan/ip/192.168.0.9
# - We still defensively check for older key formats that may include CIDR:
#   Example: /vlan/ip/192.168.0.9/24  OR /vlan/ip/192.168.0.9/24 as a single string
#   (depending on historical scripts).
# - We merge "used IPs" from:
#      A) etcd keys
#      B) Linode API VLAN interface ipam_address values
#   so we do not allocate an IP that is already set on any Linode config in the target region.
#
# Operational model
# -----------------
# - In production, this service is typically put behind a TLS terminator (Envoy/HAProxy/Nginx)
#   and/or a NodeBalancer. The Flask app itself can still listen on HTTP internally.
# - Make sure REGION and ETCD_ENDPOINTS are set (and consistent) wherever this runs.
#
# ======================================================================================

from flask import Flask, jsonify, request
from flask_cors import CORS
import os
import ipaddress
import sys
import time
import requests
import random
import signal
import configparser
import yaml
import uuid
import psutil
from datetime import datetime
from filelock import FileLock

import etcd3
from kubernetes import client, config

app = Flask(__name__)
CORS(app)

LOG_FILE = "/tmp/allocate-ip.log"
MAX_LOG_LINES = 1000
MAX_BACKOFF = 60

VLAN_IP_CACHE = {
    "ips": None,
    "timestamp": None,
    "ttl_seconds": int(os.getenv("CACHE_TTL_SECONDS", 0)),
}

REGION_CACHE = {"valid": False, "timestamp": None, "ttl_seconds": 3600}


def graceful_exit(signalnum, frame):
    log(f"[INFO] Received signal {signalnum}. Shutting down gracefully...")
    sys.exit(0)


signal.signal(signal.SIGTERM, graceful_exit)
signal.signal(signal.SIGINT, graceful_exit)


# --------------------------------------------------------------------------------------
# validate_environment()
# ----------------------
# This is a "fail-fast" guard so the app does not start in a broken state.
# - REGION: used to scope Linode API queries to the correct region.
# - ETCD_ENDPOINTS: used to connect to etcd (comma-separated host:port list).
#
# If these are missing, the service exits immediately to avoid half-working behavior
# that can later cause incorrect allocations.
# --------------------------------------------------------------------------------------

def validate_environment():
    REGION = os.getenv("REGION")
    if not REGION:
        log("[ERROR] REGION environment variable not set.")
        sys.exit(1)
    if not os.getenv("ETCD_ENDPOINTS"):
        log("[ERROR] ETCD_ENDPOINTS environment variable not set.")
        sys.exit(1)
    log("[INFO] Environment validation passed.")


# --------------------------------------------------------------------------------------
# log(message)
# ------------
# Simple logging helper:
# - Prints to stdout (so logs are visible via systemd/docker/k8s logs)
# - Also writes to a local file with a lock, keeping only the last MAX_LOG_LINES lines.
#
# File locking is used because Flask can run with multiple worker processes/threads, and
# without a lock the log file could become corrupted (interleaved writes).
# --------------------------------------------------------------------------------------

def log(message: str):
    timestamped_message = f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {message}"
    print(timestamped_message)
    sys.stdout.flush()

    try:
        with FileLock(LOG_FILE + ".lock"):
            lines = []
            if os.path.exists(LOG_FILE):
                with open(LOG_FILE, "r") as f:
                    lines = f.read().splitlines()

            lines.append(timestamped_message)
            lines = lines[-MAX_LOG_LINES:]

            with open(LOG_FILE, "w") as f:
                f.write("\n".join(lines) + "\n")
    except Exception as e:
        print(f"[ERROR] Failed to write to log file: {str(e)}")


# --------------------------------------------------------------------------------------
# _sleep_with_backoff(base_backoff, attempt, jitter=True)
# ------------------------------------------------------
# Implements exponential backoff with optional jitter.
# Jitter is important in distributed systems to avoid the "thundering herd" problem where
# many clients retry at the same time and re-trigger rate limiting.
# --------------------------------------------------------------------------------------

def _sleep_with_backoff(base_backoff, attempt, jitter=True):
    wait_time = min(base_backoff * (2 ** (attempt - 1)), MAX_BACKOFF)
    if jitter:
        wait_time += random.uniform(0.1, 0.5)
    log(f"[DEBUG] Waiting {wait_time:.2f}s before retrying...")
    time.sleep(wait_time)


# --------------------------------------------------------------------------------------
# api_request_with_retry(url, headers, ...)
# -----------------------------------------
# Wrapper around requests.get() that adds:
# - retries
# - exponential backoff
# - special handling for 429 rate limiting
#
# This is used for Linode API calls so transient failures don't cause allocation failures.
# --------------------------------------------------------------------------------------

def api_request_with_retry(url, headers, retries=3, backoff=2, jitter=True):
    for attempt in range(1, retries + 1):
        try:
            response = requests.get(url, headers=headers, timeout=8)

            if response.status_code == 200:
                try:
                    return response.json()
                except ValueError:
                    log(f"[ERROR] Invalid JSON response on attempt {attempt}: {response.text}")
                    return None

            if response.status_code == 429:
                wait_time = int(response.headers.get("Retry-After", 5))
                log(f"[WARN] Rate limited (429). Retrying after {wait_time}s (attempt {attempt}/{retries})")
                time.sleep(wait_time)
                continue

            if response.status_code >= 500:
                log(f"[WARN] Server error {response.status_code} on attempt {attempt}. Retrying...")
                _sleep_with_backoff(backoff, attempt, jitter)
                continue

            log(f"[WARN] API error {response.status_code} on attempt {attempt}. Retrying...")
            _sleep_with_backoff(backoff, attempt, jitter)

        except (requests.ConnectionError, requests.Timeout) as e:
            log(f"[ERROR] Network error on attempt {attempt}: {str(e)}. Retrying...")
            _sleep_with_backoff(backoff, attempt, jitter)
        except requests.RequestException as e:
            log(f"[ERROR] Unexpected error on attempt {attempt}: {str(e)}. Retrying...")
            _sleep_with_backoff(backoff, attempt, jitter)

    log(f"[ERROR] API call failed after {retries} attempts.")
    return None


# --------------------------------------------------------------------------------------
# normalize_ip(s)
# ---------------
# Normalizes an IP string into the *bare IP* (no CIDR suffix).
# Examples:
#   '192.168.0.9'      -> '192.168.0.9'
#   '192.168.0.9/24'   -> '192.168.0.9'
#   ' 192.168.0.9/24 ' -> '192.168.0.9'
#
# This is critical because the system historically used mixed formats in etcd:
# sometimes keys stored 'IP', sometimes 'IP/CIDR'. Normalizing prevents logic bugs.
# --------------------------------------------------------------------------------------

def normalize_ip(s: str) -> str:
    """
    Normalize anything like '192.168.0.10', '192.168.0.10/24', ' 192.168.0.10/24 '
    into bare IP: '192.168.0.10'
    """
    if not s:
        return ""
    s = s.strip()
    return s.split("/", 1)[0].strip()


# --------------------------------------------------------------------------------------
# fetch_linode_token()
# --------------------
# Reads the Linode CLI config file to obtain the API token.
# Why not use env var?
# - In some deployments the Linode CLI token is already managed on the node and this
#   avoids storing the token in multiple places.
#
# NOTE: In hardened setups, you'd prefer passing the token via a Kubernetes Secret or
# environment variable rather than reading from a file path.
# --------------------------------------------------------------------------------------

def fetch_linode_token(config_file="/root/.linode-cli/linode-cli"):
    if not os.path.exists(config_file):
        log(f"[ERROR] Configuration file {config_file} not found")
        return None

    cfg = configparser.ConfigParser()
    try:
        cfg.read(config_file)

        if "DEFAULT" not in cfg or "default-user" not in cfg["DEFAULT"]:
            log(f"[ERROR] No 'default-user' found in {config_file}")
            return None

        default_user = cfg["DEFAULT"]["default-user"]
        if default_user not in cfg:
            log(f"[ERROR] User profile '{default_user}' not found in {config_file}")
            return None

        token = cfg[default_user].get("token")
        if not token:
            log(f"[ERROR] No token found for user '{default_user}' in {config_file}")
            return None

        return token
    except Exception as e:
        log(f"[ERROR] Exception while reading configuration file: {str(e)}")
        return None


# --------------------------------------------------------------------------------------
# fetch_assigned_ips()
# --------------------
# Pulls VLAN IPs currently assigned in Linode *configs* for instances in the given REGION.
#
# Steps:
#   1) List instances in REGION (paginated)
#   2) For each instance, list configs
#   3) For each config, get config details
#   4) For each interface in config, if purpose == 'vlan', extract ipam_address
#
# Result:
#   Returns a list of BARE IPs, e.g. ['192.168.0.9', '192.168.0.10', ...]
#
# Caching:
#   VLAN_IP_CACHE is used to reduce API calls, but TTL is configurable via env var.
#   In your latest version CACHE_TTL_SECONDS=0 disables caching (always fresh).
# --------------------------------------------------------------------------------------

def fetch_assigned_ips():
    # Cache
    if (
        VLAN_IP_CACHE["ips"] is not None
        and VLAN_IP_CACHE["timestamp"] is not None
        and (datetime.now() - VLAN_IP_CACHE["timestamp"]).total_seconds() < VLAN_IP_CACHE["ttl_seconds"]
    ):
        log("[INFO] Using cached VLAN IPs")
        return VLAN_IP_CACHE["ips"]

    LINODE_TOKEN = fetch_linode_token()
    REGION = os.getenv("REGION")
    if not REGION:
        log("[ERROR] REGION environment variable not set")
        return []

    if not LINODE_TOKEN:
        log("[ERROR] Missing Linode Token")
        return []

    headers = {"Authorization": f"Bearer {LINODE_TOKEN}"}
    log(f"[DEBUG] Fetching Linode instances in region: {REGION}")

    vlan_ips = []
    page = 1
    total_pages = 1

    while page <= total_pages:
        url = f"https://api.linode.com/v4/linode/instances?page={page}&page_size=100"
        response = api_request_with_retry(url, headers={**headers, "X-Filter": f'{{"region": "{REGION}"}}'})
        if not response or "data" not in response:
            log(f"[ERROR] Failed to fetch instances on page {page}")
            break

        if page == 1:
            total_pages = response.get("pages", 1)
            log(f"[DEBUG] Total pages of instances: {total_pages}")

        for linode in response["data"]:
            linode_id = linode.get("id")
            if not linode_id:
                continue

            config_list_url = f"https://api.linode.com/v4/linode/instances/{linode_id}/configs"
            configs = api_request_with_retry(config_list_url, headers=headers)
            if not configs or "data" not in configs:
                continue

            for c in configs["data"]:
                cid = c.get("id")
                if not cid:
                    continue

                config_view_url = f"https://api.linode.com/v4/linode/instances/{linode_id}/configs/{cid}"
                config_view = api_request_with_retry(config_view_url, headers=headers)
                if not config_view or "interfaces" not in config_view:
                    continue

                for iface in config_view["interfaces"]:
                    if iface.get("purpose") == "vlan":
                        ipam = iface.get("ipam_address")
                        if ipam:
                            ip = normalize_ip(ipam)
                            if ip:
                                vlan_ips.append(ip)
                                log(f"[DEBUG] Found VLAN IP from Linode: {ip}")

        page += 1

    VLAN_IP_CACHE["ips"] = vlan_ips
    VLAN_IP_CACHE["timestamp"] = datetime.now()
    log(f"[INFO] Total VLAN IPs fetched: {len(vlan_ips)}")
    return vlan_ips


# --------------------------------------------------------------------------------------
# system_health_check()
# ---------------------
# Basic local health signals:
# - load average vs CPU count
# - memory usage %
#
# This is used in /health so we can fail fast when the VM is overloaded.
# --------------------------------------------------------------------------------------

def system_health_check():
    load_avg = os.getloadavg()
    mem = psutil.virtual_memory()
    if load_avg[0] > os.cpu_count() * 2:
        log("[WARN] High system load detected")
        return False
    if mem.percent > 90:
        log("[WARN] High memory usage detected")
        return False
    return True


# --------------------------------------------------------------------------------------
# get_etcd_connection()
# ---------------------
# Connects to the first healthy etcd endpoint from ETCD_ENDPOINTS.
# - Accepts endpoints in 'host:port' or 'http(s)://host:port' forms.
# - Calls client.status() as a health check.
#
# NOTE:
# - This uses unauthenticated etcd connectivity. If etcd is secured with TLS/auth,
#   additional parameters are needed (ca_cert, cert/key, username/password).
# --------------------------------------------------------------------------------------

def get_etcd_connection():
    endpoints = os.getenv("ETCD_ENDPOINTS", "")
    if not endpoints:
        raise EnvironmentError("ETCD_ENDPOINTS not set in environment")

    for ep in endpoints.split(","):
        ep = ep.strip().replace("http://", "").replace("https://", "").rstrip("/")
        parts = ep.split(":")
        if len(parts) != 2:
            log(f"[ERROR] Invalid ETCD endpoint format: {ep}. Expected format: host:port")
            continue

        host = parts[0]
        try:
            port = int(parts[1])
        except ValueError:
            log(f"[ERROR] Port is not a valid integer in endpoint: {ep}")
            continue

        try:
            c = etcd3.client(host=host, port=port)
            c.status()
            log(f"[INFO] Connected to etcd: {host}:{port}")
            return c
        except Exception as e:
            log(f"[WARN] Failed to connect to etcd endpoint {host}:{port}: {str(e)}")
            continue

    raise ConnectionError("Unable to connect to any etcd endpoint")


# --------------------------------------------------------------------------------------
# get_etcd()
# ----------
# Similar to get_etcd_connection(), but intended for lightweight reads (listing IPs).
# It returns the first endpoint that responds to status().
# --------------------------------------------------------------------------------------

def get_etcd():
    endpoints = os.getenv("ETCD_ENDPOINTS", "").split(",")
    for ep in endpoints:
        ep = ep.strip().replace("http://", "").replace("https://", "").rstrip("/")
        if not ep:
            continue
        if ":" in ep:
            host, port = ep.split(":")
        else:
            host, port = ep, "2379"
        try:
            c = etcd3.client(host=host, port=int(port))
            c.status()
            return c
        except Exception:
            continue
    raise RuntimeError("No healthy etcd endpoints")


# --------------------------------------------------------------------------------------
# k8s_api()
# ---------
# Initializes Kubernetes API clients.
# - First tries in-cluster config (when running inside Kubernetes)
# - Falls back to local kubeconfig (when running on a workstation/VM with kubeconfig)
#
# This is used by /api/v1/refresh endpoints to create and inspect Kubernetes Jobs.
# --------------------------------------------------------------------------------------

def k8s_api():
    try:
        config.load_incluster_config()
    except Exception:
        config.load_kube_config()
    return client.BatchV1Api(), client.CoreV1Api()


# --------------------------------------------------------------------------------------
# reserved_set(ip_net)
# --------------------
# Returns a set of IPs that should never be allocated:
# - network address (e.g., 192.168.0.0)
# - broadcast address (e.g., 192.168.0.255)
# - first usable host (often treated as gateway-like, e.g., 192.168.0.1)
#
# This matches your "reserve first two and last" intent in many /24 networks.
# Adjust if your gateway is different.
# --------------------------------------------------------------------------------------

def reserved_set(ip_net: ipaddress.IPv4Network) -> set:
    """
    Reserved:
      - network address (x.x.x.0)
      - first usable host (x.x.x.1 if available)
      - broadcast address (x.x.x.255)
    """
    res = set()
    res.add(str(ip_net.network_address))
    res.add(str(ip_net.broadcast_address))
    # first usable host if any
    hosts = list(ip_net.hosts())
    if hosts:
        res.add(str(hosts[0]))
    return res


# --------------------------------------------------------------------------------------
# POST /allocate
# --------------
# Input:
#   {"subnet": "192.168.0.0/24"}
#
# Output (success):
#   {
#     "allocated_ip": "192.168.0.9/24",
#     "ip": "192.168.0.9",
#     "cidr": "/24"
#   }
#
# Allocation flow (very important):
# 1) Parse subnet -> iterate candidate host IPs
# 2) Build a "used set" from:
#      a) etcd keys (/vlan/ip/<ip> and possibly /vlan/ip/<ip>/<cidr>)
#      b) Linode API (existing VLAN ipam_address values)
# 3) For each candidate IP not reserved/not used:
#      - Try etcd transaction:
#          compare version(/vlan/ip/<ip>) == 0 AND version(/vlan/ip/<ip>/<cidr>) == 0
#          then put /vlan/ip/<ip> = YAML payload
#      - If transaction succeeds, return that IP.
#
# The compare-and-put (transaction) is what prevents two requesters from claiming the
# same IP simultaneously.
# --------------------------------------------------------------------------------------

@app.route("/allocate", methods=["POST"])
# --------------------------------------------------------------------------------------
# POST /allocate
# --------------
# Input:
#   {"subnet": "192.168.0.0/24"}
#
# Output (success):
#   {
#     "allocated_ip": "192.168.0.9/24",
#     "ip": "192.168.0.9",
#     "cidr": "/24"
#   }
#
# Allocation flow (very important):
# 1) Parse subnet -> iterate candidate host IPs
# 2) Build a "used set" from:
#      a) etcd keys (/vlan/ip/<ip> and possibly /vlan/ip/<ip>/<cidr>)
#      b) Linode API (existing VLAN ipam_address values)
# 3) For each candidate IP not reserved/not used:
#      - Try etcd transaction:
#          compare version(/vlan/ip/<ip>) == 0 AND version(/vlan/ip/<ip>/<cidr>) == 0
#          then put /vlan/ip/<ip> = YAML payload
#      - If transaction succeeds, return that IP.
#
# The compare-and-put (transaction) is what prevents two requesters from claiming the
# same IP simultaneously.
# --------------------------------------------------------------------------------------

def allocate_ip():
    try:
        data = request.get_json(silent=True) or {}
        subnet = data.get("subnet")
        if not subnet:
            log("[ERROR] Subnet not provided")
            return jsonify({"error": "Subnet not provided"}), 400

        REGION = os.getenv("REGION")
        if not REGION:
            log("[ERROR] REGION not provided")
            return jsonify({"error": "Region not provided"}), 400

        try:
            ip_net = ipaddress.ip_network(subnet, strict=False)
            cidr_suffix = f"/{ip_net.prefixlen}"
        except ValueError:
            log("[ERROR] Invalid subnet format")
            return jsonify({"error": "Invalid subnet format"}), 400

        etcd = get_etcd_connection()

        # ---- Build used IP set from etcd (normalize BOTH old + new styles) ----
        etcd_used_bare = set()
        for _value, meta in etcd.get_prefix("/vlan/ip/"):
            if not meta.key:
                continue
            key = meta.key.decode("utf-8")
            raw = key.replace("/vlan/ip/", "", 1)        # may be '192.168.0.10' or '192.168.0.10/24'
            bare = normalize_ip(raw)
            if bare:
                etcd_used_bare.add(bare)

        # ---- Add Linode assigned VLAN IPs (bare) ----
        linode_assigned_bare = set(fetch_assigned_ips() or [])
        used_bare = etcd_used_bare.union(linode_assigned_bare)

        # ---- Sync Linode IPs into etcd using canonical bare key (atomic-ish) ----
        for bare in (linode_assigned_bare - etcd_used_bare):
            key_bare = f"/vlan/ip/{bare}"
            payload = {
                "status": "allocated",
                "source": "linode-sync",
                "region": REGION,
                "subnet": str(ip_net),
                "allocated_at": datetime.utcnow().isoformat() + "Z",
                "linode_id": None,
                "notes": "Discovered via Linode API",
            }
            try:
                etcd.transaction(
                    compare=[etcd.transactions.version(key_bare) == 0],
                    success=[etcd.transactions.put(key_bare, yaml.safe_dump(payload))],
                    failure=[],
                )
                log(f"[SYNC] Added Linode-assigned IP to etcd (bare key): {bare}")
            except Exception as e:
                log(f"[WARN] Failed syncing {bare}: {str(e)}")

        # Recompute
        used_bare = used_bare.union(linode_assigned_bare)

        res = reserved_set(ip_net)

        # Iterate usable hosts only (safe)
        for host_ip in ip_net.hosts():
            bare = str(host_ip)

            if bare in res:
                log(f"[INFO] Skipping Reserved IP: {bare}")
                continue

            if bare in used_bare:
                continue

            # Canonical key (NEW)
            key_bare = f"/vlan/ip/{bare}"

            # Old key style (if your initializer still writes it): /vlan/ip/<ip>/<prefix>
            key_old_cidr = f"/vlan/ip/{bare}{cidr_suffix}"

            payload = {
                "status": "allocated",
                "source": "api-allocate",
                "region": REGION,
                "subnet": str(ip_net),
                "allocated_at": datetime.utcnow().isoformat() + "Z",
                "linode_id": None,
                "notes": "",
            }

            try:
                # Transaction: allocate ONLY if neither bare-key nor old-cidr-key exists
                ok, _ = etcd.transaction(
                    compare=[
                        etcd.transactions.version(key_bare) == 0,
                        etcd.transactions.version(key_old_cidr) == 0,
                    ],
                    success=[
                        etcd.transactions.put(key_bare, yaml.safe_dump(payload)),
                    ],
                    failure=[],
                )

                if ok:
                    allocated_cidr = f"{bare}{cidr_suffix}"
                    log(f"[SUCCESS] Allocated IP: {allocated_cidr} (stored as bare key {key_bare})")
                    return jsonify({
                        "allocated_ip": allocated_cidr,   # backward compatible
                        "ip": bare,                       # useful for UI/logic
                        "cidr": cidr_suffix
                    }), 200

            except Exception as e:
                log(f"[ERROR] etcd transaction failed for {bare}: {str(e)}")
                return jsonify({"error": f"Failed to allocate IP: {str(e)}"}), 500

        msg = f"No IPs available in subnet {subnet}. Used={len(used_bare)}, Reserved={len(res)}"
        log(f"[ERROR] {msg}")
        return jsonify({"error": msg}), 400

    except Exception as e:
        log(f"[ERROR] Unexpected error in /allocate endpoint: {str(e)}")
        return jsonify({"error": f"Unexpected error: {str(e)}"}), 500


# --------------------------------------------------------------------------------------
# POST /release
# -------------
# Input:
#   {"ip_address": "192.168.0.9"}  OR {"ip_address": "192.168.0.9/24"}
#
# Behavior:
# - Normalizes the IP to bare form
# - Prevents releasing reserved IPs
# - Deletes both possible key styles:
#      /vlan/ip/<bare>
#      /vlan/ip/<bare>/<cidr>
# - Returns 200 if any deletion happened, else 404
# --------------------------------------------------------------------------------------

@app.route("/release", methods=["POST"])
# --------------------------------------------------------------------------------------
# POST /release
# -------------
# Input:
#   {"ip_address": "192.168.0.9"}  OR {"ip_address": "192.168.0.9/24"}
#
# Behavior:
# - Normalizes the IP to bare form
# - Prevents releasing reserved IPs
# - Deletes both possible key styles:
#      /vlan/ip/<bare>
#      /vlan/ip/<bare>/<cidr>
# - Returns 200 if any deletion happened, else 404
# --------------------------------------------------------------------------------------

def release_ip():
    try:
        data = request.get_json(silent=True) or {}
        ip_address = data.get("ip_address")
        if not ip_address:
            return jsonify({"error": "IP address not provided"}), 400

        REGION = os.getenv("REGION")
        SUBNET = os.getenv("SUBNET")
        if not REGION or not SUBNET:
            return jsonify({"error": "Missing REGION or SUBNET env variable"}), 500

        try:
            ip_net = ipaddress.ip_network(SUBNET, strict=False)
            cidr_suffix = f"/{ip_net.prefixlen}"
        except Exception:
            return jsonify({"error": "Invalid SUBNET env variable"}), 500

        bare = normalize_ip(ip_address)

        # reserved protection
        if bare in reserved_set(ip_net):
            log(f"[WARN] Attempted to release reserved IP: {bare}")
            return jsonify({"error": f"IP address {bare} is reserved and cannot be released."}), 403

        etcd = get_etcd_connection()

        key_bare = f"/vlan/ip/{bare}"
        key_old_cidr = f"/vlan/ip/{bare}{cidr_suffix}"

        deleted_any = False
        try:
            if etcd.delete(key_bare):
                deleted_any = True
            if etcd.delete(key_old_cidr):
                deleted_any = True
        except Exception as e:
            log(f"[ERROR] Release failed: {str(e)}")
            return jsonify({"error": f"Release failed: {str(e)}"}), 500

        if deleted_any:
            log(f"[INFO] Released IP from etcd: {bare} (deleted bare and/or old cidr key)")
            return jsonify({"status": "IP released", "ip": bare}), 200

        log(f"[WARN] IP {bare} not found in etcd")
        return jsonify({"error": f"IP address {bare} not found in etcd"}), 404

    except Exception as e:
        log(f"[ERROR] Unexpected error in /release endpoint: {str(e)}")
        return jsonify({"error": f"Unexpected error: {str(e)}"}), 500


# --------------------------------------------------------------------------------------
# GET /health
# -----------
# Purpose:
# - Used for readiness/liveness probes and general diagnostics.
#
# Checks:
# 1) Linode token readable
# 2) Linode API reachable (/account and /networking/ips)
# 3) etcd reachable (status)
# 4) local system health (CPU/mem)
# --------------------------------------------------------------------------------------

@app.route("/health", methods=["GET"])
# --------------------------------------------------------------------------------------
# GET /health
# -----------
# Purpose:
# - Used for readiness/liveness probes and general diagnostics.
#
# Checks:
# 1) Linode token readable
# 2) Linode API reachable (/account and /networking/ips)
# 3) etcd reachable (status)
# 4) local system health (CPU/mem)
# --------------------------------------------------------------------------------------

def health_check():
    try:
        linode_token = fetch_linode_token()
        if not linode_token:
            log("[ERROR] Health check: Failed to validate Linode CLI configuration")
            return jsonify({"status": "unhealthy", "error": "Invalid Linode CLI configuration"}), 500

        headers = {"Authorization": f"Bearer {linode_token}"}
        REGION = os.getenv("REGION")
        if not REGION:
            log("[ERROR] Health check: REGION environment variable not set")
            return jsonify({"status": "unhealthy", "error": "REGION environment variable not set"}), 500

        start_time = time.time()
        response = requests.get("https://api.linode.com/v4/account", headers=headers, timeout=8)
        latency_ms = (time.time() - start_time) * 1000

        if response.status_code == 401:
            return jsonify({"status": "unhealthy", "error": "Unauthorized access"}), 500
        if response.status_code != 200:
            return jsonify({"status": "unhealthy", "error": "Failed to connect to Linode API"}), 500

        response = requests.get("https://api.linode.com/v4/networking/ips", headers=headers, timeout=8)
        if response.status_code != 200:
            return jsonify({"status": "unhealthy", "error": "Failed to access networking API"}), 500

        # etcd
        etcd = get_etcd_connection()
        etcd.status()

        if not system_health_check():
            return jsonify({"status": "unhealthy", "error": "System health checks failed"}), 500

        return jsonify({"status": "healthy", "latency_ms": latency_ms}), 200

    except Exception as e:
        log(f"[ERROR] Health check: {str(e)}")
        return jsonify({"status": "unhealthy", "error": str(e)}), 500


# --------------------------------------------------------------------------------------
# GET /api/v1/vlan-ips
# --------------------
# Returns the set of IPs currently recorded in etcd under ETCD_PREFIX (default /vlan/ip/).
# This endpoint is typically consumed by your future "VLAN IP inventory dashboard".
#
# Note:
# - We normalize keys to bare IP so historical key formats do not create duplicates in UI.
# --------------------------------------------------------------------------------------

@app.get("/api/v1/vlan-ips")
# --------------------------------------------------------------------------------------
# GET /api/v1/vlan-ips
# --------------------
# Returns the set of IPs currently recorded in etcd under ETCD_PREFIX (default /vlan/ip/).
# This endpoint is typically consumed by your future "VLAN IP inventory dashboard".
#
# Note:
# - We normalize keys to bare IP so historical key formats do not create duplicates in UI.
# --------------------------------------------------------------------------------------

def list_ips():
    prefix = os.getenv("ETCD_PREFIX", "/vlan/ip/")
    ips = []
    etcd = get_etcd()

    for _value, meta in etcd.get_prefix(prefix):
        key = meta.key.decode()
        raw = key.split(prefix, 1)[1]
        bare = normalize_ip(raw)
        if bare:
            ips.append(bare)

    ips = sorted(set(ips), key=lambda s: [int(x) for x in s.split(".")])
    return jsonify({"ips": ips})


# --------------------------------------------------------------------------------------
# POST /api/v1/refresh
# --------------------
# Creates a new run of the VLAN IP initializer job inside Kubernetes to re-sync etcd
# with current Linode allocations.
#
# Safety:
# - We generate a unique job name using UUID suffix so multiple refresh requests do not
#   clash. (You will still want server-side rate limiting/capping to avoid spam.)
# --------------------------------------------------------------------------------------

@app.post("/api/v1/refresh")
# --------------------------------------------------------------------------------------
# POST /api/v1/refresh
# --------------------
# Creates a new run of the VLAN IP initializer job inside Kubernetes to re-sync etcd
# with current Linode allocations.
#
# Safety:
# - We generate a unique job name using UUID suffix so multiple refresh requests do not
#   clash. (You will still want server-side rate limiting/capping to avoid spam.)
# --------------------------------------------------------------------------------------

def refresh():
    ns = os.getenv("NAMESPACE", "kube-system")
    manifest_path = "/manifests/05-vlan-ip-initializer-job.yaml"

    with open(manifest_path, "r") as f:
        job_def = yaml.safe_load(f)

    base_name = job_def["metadata"]["name"]
    run_name = f"{base_name}-{uuid.uuid4().hex[:6]}"
    job_def["metadata"]["name"] = run_name
    job_def["metadata"]["namespace"] = ns

    batch, _ = k8s_api()
    batch.create_namespaced_job(namespace=ns, body=job_def)
    return jsonify({"jobName": run_name})


# --------------------------------------------------------------------------------------
# GET /api/v1/refresh/<job_name>/detail
# ------------------------------------
# Provides:
# - Job status (Running/Succeeded/Failed)
# - start/completion timestamps (if available)
# - best-effort pod logs (tail)
#
# This is meant to power the UI "Refresh status" view.
# --------------------------------------------------------------------------------------

@app.get("/api/v1/refresh/<job_name>/detail")
# --------------------------------------------------------------------------------------
# GET /api/v1/refresh/<job_name>/detail
# ------------------------------------
# Provides:
# - Job status (Running/Succeeded/Failed)
# - start/completion timestamps (if available)
# - best-effort pod logs (tail)
#
# This is meant to power the UI "Refresh status" view.
# --------------------------------------------------------------------------------------

def refresh_detail(job_name):
    ns = os.getenv("NAMESPACE", "kube-system")
    batch, core = k8s_api()
    job = batch.read_namespaced_job_status(job_name, ns)

    status = "Running"
    started_at = job.status.start_time.isoformat() if job.status.start_time else None
    completed_at = None

    if job.status.completion_time:
        completed_at = job.status.completion_time.isoformat()
        status = "Succeeded"

    for c in (job.status.conditions or []):
        if c.type == "Failed" and c.status == "True":
            status = "Failed"
            if not completed_at and c.last_transition_time:
                completed_at = c.last_transition_time.isoformat()

    # best-effort pod logs
    pod_name, logs = None, ""
    pods = core.list_namespaced_pod(ns)
    for p in pods.items:
        if p.metadata and p.metadata.name and job_name in p.metadata.name:
            pod_name = p.metadata.name
            try:
                logs = core.read_namespaced_pod_log(name=pod_name, namespace=ns, tail_lines=500)
            except Exception:
                pass
            break

    return jsonify({
        "status": status,
        "startedAt": started_at,
        "completedAt": completed_at,
        "podName": pod_name,
        "logs": logs,
    })


if __name__ == "__main__":
    validate_environment()
    #print("DEBUG VLAN IPs from Linode:", fetch_assigned_ips())
    #app.run(host="0.0.0.0", port=8080, debug=True)
    app.run(host="0.0.0.0", port=8080, debug=False)
