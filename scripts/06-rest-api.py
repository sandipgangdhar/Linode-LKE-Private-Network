#!/usr/bin/env python3
import os
import requests
import json
from flask import Flask, request, jsonify, abort
import os
import subprocess

app = Flask(__name__)

# === Initialize Environment Variables ===
# Get the hostname
hostname = subprocess.check_output("hostname", shell=True).decode().strip()

# Set the environment variable
os.environ['POD_NAME'] = hostname

# Verify the environment variable is set
print("POD_NAME:", os.getenv('POD_NAME'))

# Environment Variables
LEADER_ANNOTATION = os.getenv("LEADER_ANNOTATION", "vlan-manager-leader")
POD_NAME = os.getenv("POD_NAME", "unknown-pod")
NAMESPACE = os.getenv("NAMESPACE", "kube-system")
API_SERVER = os.getenv("API_SERVER", "https://kubernetes.default.svc")
SERVICE_ACCOUNT_TOKEN = "/var/run/secrets/kubernetes.io/serviceaccount/token"
CACERT = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
IP_LIST_FILE = "/mnt/vlan-ip/vlan-ip-list.txt"
LOCK_FILE = "/mnt/vlan-ip/vlan-ip-list.lock"


# Kubernetes API Headers
def get_headers():
    with open(SERVICE_ACCOUNT_TOKEN, "r") as token_file:
        token = token_file.read()
    return {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    }

# Kubernetes API Call
def k8s_api_call(method, path, data=None):
    url = f"{API_SERVER}{path}"
    headers = get_headers()
    response = requests.request(method, url, headers=headers, json=data, verify=CACERT)
    response.raise_for_status()
    return response.json()

# Leader Check
def is_leader():
    try:
        cm = k8s_api_call("GET", f"/api/v1/namespaces/{NAMESPACE}/configmaps/{LEADER_ANNOTATION}")
        return cm.get("metadata", {}).get("annotations", {}).get("leader") == POD_NAME
    except requests.HTTPError as e:
        print(f"[ERROR] Kubernetes API Error: {e}")
        return False

# Read the Subnet from the first line of IP List
def get_subnet_and_range():
    try:
        with open(IP_LIST_FILE, "r") as file:
            first_line = file.readline().strip()
            subnet, prefix = first_line.split('/')
            total_ips = 2 ** (32 - int(prefix))
            return subnet, total_ips
    except Exception as e:
        print(f"[ERROR] Failed to read subnet info: {e}")
        abort(500)

# Read allocated IPs
def read_allocated_ips():
    try:
        with open(IP_LIST_FILE, "r") as file:
            next(file)  # Skip the first line (subnet definition)
            return {line.split(",")[0].strip() for line in file}
    except Exception as e:
        print(f"[ERROR] Failed to read allocated IPs: {e}")
        abort(500)

# IP Allocation
@app.route('/allocate', methods=['POST'])
def allocate_ip():
    if not is_leader():
        return jsonify({"error": "Not the leader"}), 403

    # Read the subnet from the first line
    with open(IP_LIST_FILE, "r") as ip_list:
        first_line = ip_list.readline().strip()
        subnet = first_line

    # Extract subnet details
    base_ip, prefix = subnet.split('/')
    prefix = int(prefix)
    total_ips = 2**(32 - prefix)

    # Read all allocated IPs from the list
    allocated_ips = set()
    with open(IP_LIST_FILE, "r") as ip_list:
        for line in ip_list:
            if ',' in line:
                ip, status = line.strip().split(',')
                allocated_ips.add(ip)

    # Generate IP addresses dynamically
    base_octets = base_ip.split('.')
    for i in range(1, total_ips - 1):
        octet3 = (i // 256) % 256
        octet4 = i % 256
        candidate_ip = f"{base_octets[0]}.{base_octets[1]}.{octet3}.{octet4}"
        if candidate_ip not in allocated_ips:
            with open(IP_LIST_FILE, "a") as ip_list:
                ip_list.write(f"{candidate_ip},USED\n")
            print(f"[INFO] Allocated IP: {candidate_ip}/{prefix}")
            return jsonify({"allocated_ip": f"{candidate_ip}/{prefix}"})

    return jsonify({"error": "No IP available"}), 500

# IP Release
@app.route('/release', methods=['POST'])
def release_ip():
    if not is_leader():
        return jsonify({"error": "Not the leader"}), 403

    ip_to_release = request.json.get("ip")
    if not ip_to_release:
        return jsonify({"error": "IP address not provided"}), 400

    found = False
    lines = []

    # Read the file and check if the IP is used
    with open("/mnt/vlan-ip/vlan-ip-list.txt", "r") as f:
        lines = f.readlines()

    # Loop through the lines and find the IP
    for i, line in enumerate(lines):
        if line.startswith(ip_to_release) and "USED" in line:
            found = True
            lines[i] = f"{ip_to_release},AVAILABLE\n"
            break

    # If IP was found and changed to AVAILABLE, write back to the file
    if found:
        with open("/mnt/vlan-ip/vlan-ip-list.txt", "w") as f:
            f.writelines(lines)
        print(f"[INFO] Released IP: {ip_to_release}")
        return jsonify({"released_ip": ip_to_release})
    else:
        print(f"[ERROR] IP address not found or not used: {ip_to_release}")
        return jsonify({"error": "IP address not found or not in use"}), 404

# Flask app runner
if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8081)
