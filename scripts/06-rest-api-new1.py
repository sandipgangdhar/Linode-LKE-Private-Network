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

app = Flask(__name__)
CORS(app)

# File paths
IP_FILE_PATH = "/mnt/vlan-ip/vlan-ip-list.txt"
LOG_FILE = "/tmp/allocate-ip.log"
MAX_LOG_LINES = 1000
MAX_BACKOFF = 60
FALLBACK_REGIONS = ['us-east', 'us-west', 'in-maa', 'eu-west', 'eu-central']

VLAN_IP_CACHE = {
    "ips": None,
    "timestamp": None,
    "ttl_seconds": int(os.getenv("CACHE_TTL_SECONDS", 60))
}
REGION_CACHE = {"valid": False, "timestamp": None, "ttl_seconds": 3600}

# Signal handlers for graceful shutdown
def graceful_exit(signalnum, frame):
    log(f"[INFO] Received signal {signalnum}. Shutting down gracefully...")
    sys.exit(0)

signal.signal(signal.SIGTERM, graceful_exit)
signal.signal(signal.SIGINT, graceful_exit)

# Async region fetching
async def fetch_regions_async(headers, retries=3, backoff=2):
    async with aiohttp.ClientSession() as session:
        for attempt in range(retries):
            try:
                async with session.get("https://api.linode.com/v4/regions", headers=headers, timeout=5) as response:
                    if response.status == 200:
                        data = await response.json()
                        return [r["id"] for r in data.get("data", [])]
                    elif response.status == 429:
                        wait_time = int(response.headers.get('Retry-After', 5))
                        log(f"[WARN] Rate limited (429). Retrying after {wait_time} seconds...")
                        await asyncio.sleep(wait_time)
                    else:
                        log(f"[WARN] API call failed with status {response.status}. Retrying in {backoff} seconds...")
                        await asyncio.sleep(backoff)
                        backoff = min(backoff * 2, MAX_BACKOFF)
            except aiohttp.ClientError as e:
                log(f"[ERROR] Network error during async API call: {str(e)}. Retrying in {backoff} seconds...")
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, MAX_BACKOFF)
        log("[ERROR] Failed to fetch regions after retries")
        return None

async def update_regions_cache():
    linode_token = fetch_linode_token()
    if linode_token:
        headers = {"Authorization": f"Bearer {linode_token}"}
        regions = await fetch_regions_async(headers)
        if regions:
            global FALLBACK_REGIONS
            FALLBACK_REGIONS = regions
            log(f"[INFO] Updated fallback regions: {FALLBACK_REGIONS}")

async def schedule_region_updates():
    while True:
        await update_regions_cache()
        await asyncio.sleep(600)

def validate_environment():
    errors = []
    REGION = os.getenv("REGION")
    if not REGION:
        errors.append("REGION environment variable not set")
    else:
        linode_token = fetch_linode_token()
        valid_regions = FALLBACK_REGIONS
        if linode_token:
            headers = {"Authorization": f"Bearer {linode_token}"}
            response = api_request_with_retry("https://api.linode.com/v4/regions", headers)
            if response:
                valid_regions = [r["id"] for r in response.get("data", [])]
                log(f"[DEBUG] Valid Linode regions: {valid_regions}")
            else:
                asyncio.create_task(schedule_region_updates())
        if REGION not in valid_regions:
            errors.append(f"Invalid region: {REGION}. Valid regions: {valid_regions}")
    
    ip_dir = os.path.dirname(IP_FILE_PATH)
    if not os.access(ip_dir, os.W_OK):
        errors.append(f"No write permission for directory {ip_dir}")
    
    log_dir = os.path.dirname(LOG_FILE)
    if not os.access(log_dir, os.W_OK):
        errors.append(f"No write permission for directory {log_dir}")
    
    try:
        requests.get("https://api.linode.com/v4/regions", timeout=5)
    except requests.RequestException:
        errors.append("No network connectivity to Linode API")
    
    if errors:
        for error in errors:
            log(f"[ERROR] {error}")
        sys.exit(1)

def log(message):
    print(message)
    sys.stdout.flush()
    with FileLock(LOG_FILE + ".lock"):
        try:
            lines = []
            if os.path.exists(LOG_FILE):
                with open(LOG_FILE, "r") as f:
                    lines = f.read().splitlines()
            lines.append(message)
            lines = lines[-MAX_LOG_LINES:]
            with open(LOG_FILE, "w") as f:
                f.write("\n".join(lines) + "\n")
        except Exception as e:
            print(f"[ERROR] Failed to write to log file: {str(e)}")

def api_request_with_retry(url, headers, retries=3, backoff=2):
    for attempt in range(retries):
        try:
            response = requests.get(url, headers=headers, timeout=5)
            if response.status_code == 200:
                try:
                    return response.json()
                except ValueError as e:
                    log(f"[ERROR] Invalid JSON response: {response.text}")
                    return None
            elif response.status_code == 429:
                wait_time = int(response.headers.get('Retry-After', 5))
                log(f"[WARN] Rate limited (429). Retrying after {wait_time} seconds...")
                time.sleep(wait_time)
            elif response.status_code >= 500:
                log(f"[WARN] Server error {response.status_code}. Retrying in {backoff} seconds...")
                time.sleep(backoff)
                backoff = min(backoff * 2, MAX_BACKOFF)
            else:
                log(f"[WARN] API call failed with status {response.status_code}. Retrying in {backoff} seconds...")
                time.sleep(backoff)
                backoff = min(backoff * 2, MAX_BACKOFF)
        except requests.ConnectionError as e:
            log(f"[ERROR] Connection error during API call: {str(e)}. Retrying in {backoff} seconds...")
            time.sleep(backoff)
            backoff = min(backoff * 2, MAX_BACKOFF)
        except requests.Timeout as e:
            log(f"[ERROR] Timeout during API call: {str(e)}. Retrying in {backoff} seconds...")
            time.sleep(backoff)
            backoff = min(backoff * 2, MAX_BACKOFF)
        except requests.RequestException as e:
            log(f"[ERROR] Other network error during API call: {str(e)}. Retrying in {backoff} seconds...")
            time.sleep(backoff)
            backoff = min(backoff * 2, MAX_BACKOFF)
    log(f"[ERROR] API call failed after {retries} attempts.")
    return None

def fetch_linode_token():
    LINODE_CLI_CONFIG = os.getenv("LINODE_CLI_CONFIG", "/root/.linode-cli/linode-cli")
    try:
        with open(LINODE_CLI_CONFIG, "r") as f:
            for line in f:
                if "token" in line:
                    token = line.split('= ')[1].strip()
                    log(f"[DEBUG] Linode Token fetched successfully")
                    headers = {"Authorization": f"Bearer {token}"}
                    response = requests.get("https://api.linode.com/v4/account", headers=headers, timeout=5)
                    if response.status_code == 200:
                        log(f"[DEBUG] Linode Token validated successfully")
                        return token
                    else:
                        log(f"[ERROR] Token validation failed with status {response.status_code}")
                        return None
        log(f"[ERROR] Token not found in {LINODE_CLI_CONFIG}")
        return None
    except FileNotFoundError:
        log(f"[ERROR] Linode config file {LINODE_CLI_CONFIG} not found")
        return None
    except requests.RequestException as e:
        log(f"[ERROR] Network error during token validation: {str(e)}")
        return None
    except Exception as e:
        log(f"[ERROR] Exception while fetching Linode token: {str(e)}")
        return None

def remove_duplicates():
    with FileLock(IP_FILE_PATH + ".lock"):
        try:
            with open(IP_FILE_PATH, 'r') as f:
                unique_lines = set(f.read().splitlines())
            with open(IP_FILE_PATH, 'w') as f:
                f.write("\n".join(unique_lines) + "\n")
            log(f"[INFO] Removed duplicates from IP file. Unique IPs: {len(unique_lines)}")
        except FileNotFoundError:
            log(f"[WARNING] IP file {IP_FILE_PATH} not found during deduplication")

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
    log(f"[DEBUG] Fetching VLAN IPs for region: {REGION}")

    url = "https://api.linode.com/v4/linode/instances"
    instances = api_request_with_retry(url, headers={"Authorization": f"Bearer {LINODE_TOKEN}", "X-Filter": f'{{"region": "{REGION}"}}'})
    
    if not instances:
        log("[ERROR] Failed to fetch Linode instances")
        return None

    linode_ids = [str(l["id"]) for l in instances.get("data", [])]
    log(f"[DEBUG] Linode IDs fetched: {linode_ids}")

    vlan_ips = []
    def fetch_configs(linode_id):
        log(f"[DEBUG] Fetching VLAN IPs for Linode ID: {linode_id}")
        config_url = f"https://api.linode.com/v4/linode/instances/{linode_id}/configs"
        configs = api_request_with_retry(config_url, headers)
        if not configs:
            log(f"[ERROR] Failed to fetch configurations for Linode ID {linode_id}")
            return []
        linode_vlan_ips = []
        for config in configs.get("data", []):
            for iface in config.get("interfaces", []):
                if iface.get("purpose") == "vlan":
                    ip_address = iface.get("ipam_address")
                    if ip_address:
                        linode_vlan_ips.append(ip_address)
                        log(f"[DEBUG] Found VLAN IP: {ip_address}")
        return linode_vlan_ips

    max_workers = int(os.getenv("MAX_WORKERS", 20))
    max_workers = min(max_workers, max(1, len(linode_ids)))
    if max_workers == 1 and len(linode_ids) > 1:
        log(f"[WARN] Only 1 worker thread available with {len(linode_ids)} Linode instances. Possible API rate limiting.")
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        results = executor.map(fetch_configs, linode_ids)
        for result in results:
            vlan_ips.extend(result)

    log(f"[DEBUG] All VLAN IPs in region {REGION}: {vlan_ips}")

    VLAN_IP_CACHE["ips"] = vlan_ips
    VLAN_IP_CACHE["timestamp"] = datetime.now()
    
    return vlan_ips

def safe_update_ip_list(ips):
    with FileLock(IP_FILE_PATH + ".lock"):
        with open(IP_FILE_PATH, 'a') as f:
            f.write("\n".join(str(ip) for ip in ips) + "\n")
    log(f"[INFO] Successfully wrote {len(ips)} IPs to file: {ips}")

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

        remove_duplicates()
        linode_ips = fetch_assigned_ips()
        
        if linode_ips is None:
            log("[ERROR] Cannot allocate IP due to Linode API failure")
            return jsonify({"error": "Cannot allocate IP due to Linode API failure"}), 500

        log(f"[DEBUG] Assigned VLAN IPs found in Linode: {linode_ips}")

        ip_list = []
        try:
            with FileLock(IP_FILE_PATH + ".lock"):
                with open(IP_FILE_PATH, 'r') as f:
                    ip_list = [line.strip() for line in f.read().splitlines() if line.strip()]
            log(f"[DEBUG] Local IP List from file: {ip_list}")
        except FileNotFoundError:
            log(f"[WARNING] IP file {IP_FILE_PATH} not found, treating as empty")
            ip_list = []

        local_ip_set = set(ip_list)
        linode_ip_set = set(linode_ips) if linode_ips else set()

        new_linode_ips = linode_ip_set - local_ip_set
        if new_linode_ips:
            try:
                safe_update_ip_list(list(new_linode_ips))
                local_ip_set.update(new_linode_ips)
                log(f"[DEBUG] Local IP List after syncing Linode IPs: {list(local_ip_set)}")
            except Exception as e:
                log(f"[ERROR] Failed to sync Linode IPs: {str(e)}")
                return jsonify({"error": f"Failed to sync Linode IPs: {str(e)}"}), 500

        log(f"[DEBUG] --- Begin IP Scan ---")

        attempted_ips = []
        skipped_local = 0
        skipped_linode = 0

        for ip in ip_net.hosts():
            candidate_ip = f"{ip}{cidr_suffix}"
            attempted_ips.append(candidate_ip)
            log(f"[DEBUG] Checking Candidate IP: {candidate_ip}")

            if candidate_ip in local_ip_set:
                log(f"[INFO] Skipping IP (Already allocated locally): {candidate_ip}")
                skipped_local += 1
                continue
            if candidate_ip in linode_ip_set:
                log(f"[INFO] Skipping IP (Already allocated in Linode): {candidate_ip}")
                skipped_linode += 1
                continue

            try:
                safe_update_ip_list([candidate_ip])
                log(f"[SUCCESS] Allocated IP: {candidate_ip}")
                return jsonify({"allocated_ip": candidate_ip}), 200
            except OSError as e:
                log(f"[ERROR] Failed to allocate IP {candidate_ip}: {str(e)}")
                return jsonify({"error": f"Failed to allocate IP: {str(e)}"}), 500

        error_msg = (
            f"No IPs available in subnet {subnet}. "
            f"Attempted {len(attempted_ips)} IPs: {skipped_local} already allocated locally, "
            f"{skipped_linode} already allocated in Linode."
        )
        log(f"[ERROR] {error_msg}")
        return jsonify({"error": error_msg}), 400

    except ValueError as e:
        log(f"[ERROR] Invalid input in /allocate endpoint: {str(e)}")
        return jsonify({"error": f"Invalid input: {str(e)}"}), 400
    except requests.RequestException as e:
        log(f"[ERROR] Network error in /allocate endpoint: {str(e)}")
        return jsonify({"error": f"Network error: {str(e)}"}), 500
    except Exception as e:
        log(f"[ERROR] Unexpected error in /allocate endpoint: {str(e)}")
        return jsonify({"error": f"Unexpected error: {str(e)}"}), 500

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
            with FileLock(IP_FILE_PATH + ".lock"), open(IP_FILE_PATH, 'a'):
                pass
        except OSError as e:
            log(f"[ERROR] Health check: Failed to access IP file: {str(e)}")
            return jsonify({"status": "unhealthy", "error": f"Failed to access IP file: {str(e)}"}), 500

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

if __name__ == '__main__':
    validate_environment()
    app.run(host='0.0.0.0', port=8080, debug=True)
