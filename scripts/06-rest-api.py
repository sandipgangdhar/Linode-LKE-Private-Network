# Import necessary libraries for web server, concurrency, networking, and file handling
from flask import Flask, jsonify, request
from flask_cors import CORS
import os
import ipaddress
import json
import sys
import time
from filelock import FileLock
import requests
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
import asyncio
import aiohttp
import psutil
import signal
import configparser
import etcd3
import random

# Initialize Flask application instance
app = Flask(__name__)
# Enable Cross-Origin Resource Sharing (CORS) for this Flask app
CORS(app)

# Define the log file path for logging allocation and healthcheck events
LOG_FILE = "/tmp/allocate-ip.log"

# Maximum number of log lines to retain in the log file
MAX_LOG_LINES = 1000

# Maximum backoff time in seconds for retry loops (e.g., API retries)
MAX_BACKOFF = 60

# Cache dictionary to store VLAN IPs with a TTL for performance
VLAN_IP_CACHE = {
    "ips": None,
    "timestamp": None,
    "ttl_seconds": int(os.getenv("CACHE_TTL_SECONDS", 60))
}

# Cache to validate region metadata to reduce repetitive API calls
REGION_CACHE = {"valid": False, "timestamp": None, "ttl_seconds": 3600}


# Signal handler to gracefully shutdown the app when terminated
def graceful_exit(signalnum, frame):
    log(f"[INFO] Received signal {signalnum}. Shutting down gracefully...")
    sys.exit(0)


# Register signal handlers for SIGTERM and SIGINT (Ctrl+C)
signal.signal(signal.SIGTERM, graceful_exit)

# Register signal handlers for SIGTERM and SIGINT (Ctrl+C)
signal.signal(signal.SIGINT, graceful_exit)



def validate_environment():
    REGION = os.getenv("REGION")
    if not REGION:
        log("[ERROR] REGION environment variable not set.")
        sys.exit(1)
    if not os.getenv("ETCD_ENDPOINTS"):
        log("[ERROR] ETCD_ENDPOINTS environment variable not set.")
        sys.exit(1)

    log("[INFO] Environment validation passed.")

def log(message):
    timestamped_message = f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {message}"
    print(timestamped_message)
    sys.stdout.flush()

    try:
        with FileLock(LOG_FILE + ".lock"):
            lines = []

            # Read existing log if available
            if os.path.exists(LOG_FILE):
                with open(LOG_FILE, "r") as f:
                    lines = f.read().splitlines()

            # Append new log entry and trim if necessary
            lines.append(timestamped_message)
            lines = lines[-MAX_LOG_LINES:]

            # Write back to log file
            with open(LOG_FILE, "w") as f:
                f.write("\n".join(lines) + "\n")
    except Exception as e:
        print(f"[ERROR] Failed to write to log file: {str(e)}")


def api_request_with_retry(url, headers, retries=3, backoff=2, jitter=True):
    """
    Make an HTTP GET request with retry, exponential backoff, and optional jitter.
    """
    for attempt in range(1, retries + 1):
        try:
            response = requests.get(url, headers=headers, timeout=5)

            if response.status_code == 200:
                try:
                    return response.json()
                except ValueError:
                    log(f"[ERROR] Invalid JSON response on attempt {attempt}: {response.text}")
                    return None

            elif response.status_code == 429:
                wait_time = int(response.headers.get("Retry-After", 5))
                log(f"[WARN] Rate limited (429). Retrying after {wait_time}s (attempt {attempt}/{retries})")
                time.sleep(wait_time)

            elif response.status_code >= 500:
                log(f"[WARN] Server error {response.status_code} on attempt {attempt}. Retrying...")
                _sleep_with_backoff(backoff, attempt, jitter)

            else:
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


def _sleep_with_backoff(base_backoff, attempt, jitter=True):
    wait_time = min(base_backoff * (2 ** (attempt - 1)), MAX_BACKOFF)
    if jitter:
        wait_time += random.uniform(0.1, 0.5)
    log(f"[DEBUG] Waiting {wait_time:.2f}s before retrying...")
    time.sleep(wait_time)


def fetch_linode_token(config_file='/root/.linode-cli/linode-cli'):
    """
    Read the Linode CLI config file and extract the token for the default user.

    Args:
        config_file (str): Path to the Linode CLI configuration file

    Returns:
        str: The token value, or None if not found
    """
    if not os.path.exists(config_file):
        log(f"[ERROR] Configuration file {config_file} not found")
        return None

    config = configparser.ConfigParser()

    try:
        config.read(config_file)

        if 'DEFAULT' not in config or 'default-user' not in config['DEFAULT']:
            log(f"[ERROR] No 'default-user' found in {config_file}")
            return None

        default_user = config['DEFAULT']['default-user']

        if default_user not in config:
            log(f"[ERROR] User profile '{default_user}' not found in {config_file}")
            return None

        token = config[default_user].get('token')
        if not token:
            log(f"[ERROR] No token found for user '{default_user}' in {config_file}")
            return None

        return token

    except Exception as e:
        log(f"[ERROR] Exception while reading configuration file: {str(e)}")
        return None

def fetch_assigned_ips():
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
        raise EnvironmentError("REGION environment variable not set")
    if not LINODE_TOKEN:
        log("[ERROR] Missing Linode Token")
        return None

    headers = {"Authorization": f"Bearer {LINODE_TOKEN}"}
    log(f"[DEBUG] Fetching Linode instances in region: {REGION}")

    vlan_ips = []
    page = 1
    total_pages = 1  # will be updated after first call

    while page <= total_pages:
        url = f"https://api.linode.com/v4/linode/instances?page={page}&page_size=100"
        response = api_request_with_retry(url, headers={**headers, "X-Filter": f'{{"region": "{REGION}"}}'})

        if not response or "data" not in response:
            log(f"[ERROR] Failed to fetch instances on page {page}")
            break

        if page == 1:
            total_pages = response.get("pages", 1)
            log(f"[DEBUG] Total pages of instances: {total_pages}")

        linodes = response["data"]
        for linode in linodes:
            linode_id = linode.get("id")
            if not linode_id:
                continue

            # Step 1: Get config list
            config_list_url = f"https://api.linode.com/v4/linode/instances/{linode_id}/configs"
            configs = api_request_with_retry(config_list_url, headers=headers)
            if not configs or "data" not in configs:
                continue

            for config in configs["data"]:
                config_id = config.get("id")
                if not config_id:
                    continue

                # Step 2: Get config view
                config_view_url = f"https://api.linode.com/v4/linode/instances/{linode_id}/configs/{config_id}"
                config_view = api_request_with_retry(config_view_url, headers=headers)
                if not config_view or "interfaces" not in config_view:
                    continue

                # Step 3: Extract VLAN IPs
                for iface in config_view["interfaces"]:
                    if iface.get("type") == "vlan":
                        ipam_address = iface.get("ipam_address")
                        if ipam_address:
                            ip = ipam_address.split("/")[0]
                            vlan_ips.append(ip)
                            log(f"[DEBUG] Found VLAN IP: {ip}")

        page += 1

    log(f"[INFO] Total VLAN IPs fetched: {len(vlan_ips)}")
    VLAN_IP_CACHE["ips"] = vlan_ips
    VLAN_IP_CACHE["timestamp"] = datetime.now()

    return vlan_ips

def system_health_check():
    load_avg = os.getloadavg()
    mem = psutil.virtual_memory()
    mem_info = f"Total: {mem.total / (1024 ** 2):.2f} MB, Used: {mem.used / (1024 ** 2):.2f} MB, Free: {mem.free / (1024 ** 2):.2f} MB"
    log(f"[INFO] System Load Average: {load_avg}")
    log(f"[INFO] Memory Information: {mem_info}")
    if load_avg[0] > os.cpu_count() * 2:
        log("[WARN] High system load detected")
        return False
    if mem.percent > 90:
        log("[WARN] High memory usage detected")
        return False
    return True

def get_etcd_connection():
    endpoints = os.getenv("ETCD_ENDPOINTS", "")
    if not endpoints:
        raise EnvironmentError("ETCD_ENDPOINTS not set in environment")

    # Try each endpoint until successful
    for ep in endpoints.split(","):
        ep = ep.replace("http://", "").replace("https://", "").rstrip("/")  # Normalize scheme and slashes

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
            client = etcd3.client(host=host, port=port)
            client.status()  # Health check
            log(f"[INFO] Connected to etcd: {host}:{port}")
            return client
        except Exception as e:
            log(f"[WARN] Failed to connect to etcd endpoint {host}:{port}: {str(e)}")
            continue

    raise ConnectionError("Unable to connect to any etcd endpoint")


# =======================
# 🟢 Allocate IP Endpoint Sandip
# =======================
@app.route('/allocate', methods=['POST'])
def allocate_ip():
    try:
        subnet = request.json.get('subnet')
        if not subnet:
            log("[ERROR] Subnet not provided")
            return jsonify({"error": "Subnet not provided"}), 400

        REGION = os.getenv("REGION")
        if not REGION:
            log("[ERROR] Region not provided")
            return jsonify({"error": "Region not provided"}), 400

        log(f"[DEBUG] Subnet: {subnet}, Region: {REGION}")

        try:
            ip_net = ipaddress.ip_network(subnet, strict=False)
            cidr_suffix = f"/{ip_net.prefixlen}"
        except ValueError:
            log("[ERROR] Invalid subnet format")
            return jsonify({"error": "Invalid subnet format"}), 400

        # Connect to etcd
        etcd = get_etcd_connection()
        if not etcd:
            return jsonify({"error": "Unable to connect to etcd"}), 500

        # Fetch all IPs already used from etcd
        etcd_used_ips = set()
        for value, meta in etcd.get_prefix("/vlan/ip/"):
            if meta.key:
                etcd_used_ips.add(meta.key.decode("utf-8").replace("/vlan/ip/", ""))

        log(f"[DEBUG] IPs found in etcd: {etcd_used_ips}")

        # ✅ Fetch all Linode-assigned VLAN IPs (even if not in etcd)
        linode_assigned_ips = set(fetch_assigned_ips())

        # ✅ Merge both to get full list of used IPs
        used_ips = etcd_used_ips.union(linode_assigned_ips)

        # Sync missing IPs into etcd
        missing_in_etcd = linode_assigned_ips - etcd_used_ips
        for ip in missing_in_etcd:
            try:
                etcd.put(f"/vlan/ip/{ip}", "true")
                log(f"[SYNC] Added missing Linode-assigned IP to etcd: {ip}")
            except Exception as e:
                log(f"[ERROR] Failed to sync IP {ip} to etcd: {str(e)}")

        used_ips = etcd_used_ips.union(linode_assigned_ips)

        # Determine reserved IPs
        hosts = list(ip_net.hosts())
        if len(hosts) >= 3:
            reserved_ips = {
                str(hosts[0]),
                str(hosts[1]),
                str(hosts[-1])
            }
        else:
            reserved_ips = set()

        skipped_reserved = 0
        attempted_ips = 0

        # Begin IP scan
        for ip in hosts:
            candidate_ip = f"{ip}{cidr_suffix}"
            attempted_ips += 1

            if candidate_ip in reserved_ips:
                log(f"[INFO] Skipping Reserved IP: {candidate_ip}")
                skipped_reserved += 1
                continue

            if candidate_ip in used_ips:
                log(f"[INFO] Skipping Already Allocated IP: {candidate_ip}")
                continue

            try:
                key = f"/vlan/ip/{candidate_ip}"
                txn_success, _ = etcd.transaction(
                    compare=[
                        etcd.transactions.version(key) == 0  # Key must not exist
                    ],
                    success=[
                        etcd.transactions.put(key, "true")
                    ],
                    failure=[]
                )

                if txn_success:
                    log(f"[SUCCESS] Allocated IP: {candidate_ip}")
                    return jsonify({"allocated_ip": candidate_ip}), 200
                else:
                    log(f"[INFO] Race condition — IP was just taken: {candidate_ip}")
                    continue
            except Exception as e:
                log(f"[ERROR] etcd put failed for {candidate_ip}: {str(e)}")
                return jsonify({"error": f"Failed to allocate IP: {str(e)}"}), 500

        error_msg = (
            f"No IPs available in subnet {subnet}. "
            f"Attempted {attempted_ips} IPs, "
            f"{skipped_reserved} were reserved, "
            f"{len(used_ips)} already allocated."
        )
        log(f"[ERROR] {error_msg}")
        return jsonify({"error": error_msg}), 400

    except Exception as e:
        log(f"[ERROR] Unexpected error in /allocate endpoint: {str(e)}")
        return jsonify({"error": f"Unexpected error: {str(e)}"}), 500


# =======================
# 🔴 Release IP Endpoint
# =======================
@app.route('/release', methods=['POST'])
def release_ip():
    try:
        ip_address = request.json.get('ip_address')
        if not ip_address:
            return jsonify({"error": "IP address not provided"}), 400

        ip_address = ip_address.strip()
        REGION = os.getenv("REGION")
        SUBNET = os.getenv("SUBNET")
        if not REGION or not SUBNET:
            return jsonify({"error": "Missing REGION or SUBNET env variable"}), 500

        try:
            ip_net = ipaddress.ip_network(SUBNET, strict=False)
            cidr_suffix = f"/{ip_net.prefixlen}"
            hosts = list(ip_net.hosts())

            reserved_ips = set()
            if len(hosts) >= 3:
                reserved_ips = {
                    str(hosts[0]),
                    str(hosts[1]),
                    str(hosts[-1])
                }

            if ip_address in reserved_ips:
                log(f"[WARN] Attempted to release reserved IP: {ip_address}")
                return jsonify({"error": f"IP address {ip_address} is reserved and cannot be released."}), 403

            etcd = get_etcd_connection()
            if not etcd:
                return jsonify({"error": "Failed to connect to etcd"}), 500

            key = f"/vlan/ip/{ip_address}"
            deleted = etcd.delete(key)

            if deleted:
                log(f"[INFO] Released IP from etcd: {ip_address}")
                return jsonify({"status": "IP released", "ip": ip_address}), 200
            else:
                log(f"[WARN] IP {ip_address} not found in etcd")
                return jsonify({"error": f"IP address {ip_address} not found in etcd"}), 404

        except Exception as e:
            log(f"[ERROR] Release failed: {str(e)}")
            return jsonify({"error": f"Release failed: {str(e)}"}), 500

    except Exception as e:
        log(f"[ERROR] Unexpected error in /release endpoint: {str(e)}")
        return jsonify({"error": f"Unexpected error: {str(e)}"}), 500

# =======================
# 🔵 Health Check Endpoint
# =======================
@app.route('/health', methods=['GET'])
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
        response = requests.get("https://api.linode.com/v4/account", headers=headers, timeout=5)
        end_time = time.time()
        latency_ms = (end_time - start_time) * 1000
        if latency_ms > 200:
            log(f"[WARN] Linode API latency is high: {latency_ms:.2f} ms")
        if response.status_code == 401:
            log("[ERROR] Health check: Unauthorized access. Token might be invalid")
            return jsonify({"status": "unhealthy", "error": "Unauthorized access"}), 500
        if response.status_code != 200:
            log(f"[ERROR] Health check: Failed to connect to Linode API, status {response.status_code}")
            return jsonify({"status": "unhealthy", "error": "Failed to connect to Linode API"}), 500

        response = requests.get("https://api.linode.com/v4/networking/ips", headers=headers, timeout=5)
        if response.status_code != 200:
            log(f"[ERROR] Health check: Failed to access networking API, status {response.status_code}")
            return jsonify({"status": "unhealthy", "error": "Failed to access networking API"}), 500

        if (
                REGION_CACHE["timestamp"] is None
                or (datetime.now() - REGION_CACHE["timestamp"]).total_seconds() > REGION_CACHE["ttl_seconds"]
        ):
            response = requests.get(f"https://api.linode.com/v4/regions/{REGION}", headers=headers, timeout=5)
            if response.status_code != 200:
                log(f"[ERROR] Health check: Invalid or unavailable region {REGION}, status {response.status_code}")
                return jsonify({"status": "unhealthy", "error": f"Invalid or unavailable region {REGION}"}), 500
            REGION_CACHE["valid"] = True
            REGION_CACHE["timestamp"] = datetime.now()
        elif not REGION_CACHE["valid"]:
            log(f"[ERROR] Health check: Cached result indicates invalid region {REGION}")
            return jsonify({"status": "unhealthy", "error": f"Invalid or unavailable region {REGION}"}), 500
        try:
            etcd = get_etcd_connection()
            etcd.status()
        except Exception as e:
            log(f"[ERROR] Health check: Failed to connect to etcd: {str(e)}")
            return jsonify({"status": "unhealthy", "error": f"etcd connection failed: {str(e)}"}), 500

        if not system_health_check():
            log("[ERROR] Health check: System health checks failed")
            return jsonify({"status": "unhealthy", "error": "System health checks failed"}), 500

        log("[INFO] Health check: All checks passed")
        return jsonify({"status": "healthy", "latency_ms": latency_ms}), 200

    except requests.RequestException as e:
        log(f"[ERROR] Health check: Network connectivity error: {str(e)}")
        return jsonify({"status": "unhealthy", "error": f"Network connectivity error: {str(e)}"}), 500
    except Exception as e:
        log(f"[ERROR] Health check: Unexpected error: {str(e)}")
        return jsonify({"status": "unhealthy", "error": f"Unexpected error: {str(e)}"}), 500

# =======================
# 🚀 Start Flask Application
# =======================
if __name__ == '__main__':
    validate_environment()
    app.run(host='0.0.0.0', port=8080, debug=True)
