"""
06-rest-api.py

This script is a Flask-based REST API responsible for managing VLAN IP assignments for the Linode-LKE-Private-Network project.
It handles IP synchronization, allocation, release, and health checks. The backend is powered by SQLite for persistent storage.

-----------------------------------------------------
📝 Endpoints:

1️⃣ /allocate-ip   [POST]   - Allocates an available IP from the pool
2️⃣ /release       [POST]   - Releases an IP address back to the pool
3️⃣ /vlan-attachment [POST] - Syncs VLAN IPs when DaemonSet attaches a VLAN
4️⃣ /health        [GET]    - Health check for the API service

-----------------------------------------------------
📌 Logic Flow:

1. Database Initialization:
   - An SQLite database is used to maintain IP states.
   - IPs are marked as 'assigned' (1) or 'available' (0).

2. Linode API Sync:
   - On startup, the script syncs with the Linode API to detect existing IP allocations and updates the database.

3. IP Allocation:
   - When requested, the script checks the database for a free IP.
   - Before assigning, it double-checks with Linode CLI to ensure the IP is not already in use.

4. IP Release:
   - When an IP is released, it is marked as available again in the database.

5. VLAN Attachment Sync:
   - A DaemonSet triggers a sync whenever a VLAN interface is attached, keeping IP records updated.

-----------------------------------------------------
🔄 Usage:

- Deploy this script as a Flask app on your Linode LKE setup.
- Expose it as a service to allow DaemonSet and other components to interact with it.

-----------------------------------------------------
-----------------------------------------------------
🖋️ Author:
- Sandip Gangdhar
- GitHub: https://github.com/sandipgangdhar
© Linode-LKE-Private-Network | Developed by Sandip Gangdhar | 2025
"""
import sqlite3
import subprocess
from flask import Flask, request, jsonify

# Flask application instance
app = Flask(__name__)

# Database path for storing IP addresses
DB_PATH = '/mnt/vlan-ip/vlan-ip.db'

# Linode CLI command to list all instances
LINODE_CLI_CMD = "linode-cli linodes list --json"

# =======================
# 🔄 Initialize the SQLite database
# =======================
def initialize_db():
    """
    Initializes the SQLite database and creates the 'vlan_ips' table
    if it does not already exist.
    - ip_address: Stores the IP addresses
    - assigned: Flag to indicate if the IP is allocated (1) or available (0)
    """
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute('''CREATE TABLE IF NOT EXISTS vlan_ips (
                        ip_address TEXT PRIMARY KEY,
                        assigned INTEGER DEFAULT 0
                     )''')
    conn.commit()
    conn.close()
    print("[INFO] Database initialized successfully")

# =======================
# 🔄 Sync IP addresses with Linode API
# =======================
def sync_with_linode():
    """
    Syncs the local database with the Linode instances fetched from the API.
    - It fetches all Linode instances using the Linode CLI.
    - Parses the IP addresses from each instance.
    - Marks those IPs as 'assigned' in the local SQLite database.
    """
    print("[INFO] Syncing with Linode API...")
    # Execute the linode-cli command to fetch instances in JSON format
    linodes = subprocess.check_output(LINODE_CLI_CMD, shell=True).decode('utf-8')
    linodes_data = eval(linodes)
    active_ips = set()
    
    # Loop through each instance and collect its IP addresses
    for linode in linodes_data:
        for ip in linode.get("ipv4", []):
            active_ips.add(ip)
    
    # Update the database to mark these IPs as assigned
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    for ip in active_ips:
        cursor.execute("INSERT OR IGNORE INTO vlan_ips (ip_address, assigned) VALUES (?, 1)", (ip,))
    conn.commit()
    conn.close()
    print("[INFO] Linode IPs synced successfully")

# =======================
# 🔎 Check if the IP is available using linode-cli
# =======================
def is_ip_available(ip_address):
    """
    Checks if the given IP address is available using Linode CLI.
    - It executes a CLI command to list all networking IPs.
    - If the IP is found in the list, it returns False (not available).
    - If the IP is not found, it returns True (available for assignment).
    """
    check_cmd = f"linode-cli networking ip-list | grep '{ip_address}'"
    result = subprocess.run(check_cmd, shell=True, stdout=subprocess.PIPE)
    return result.returncode != 0

# =======================
# 🟢 Allocate an IP address
# =======================
@app.route('/allocate-ip', methods=['POST'])
def allocate_ip():
    """
    API Endpoint to allocate an available IP address from the database.
    - It queries the database for the first available IP (assigned = 0).
    - Before returning, it performs a live check with Linode CLI to verify the IP is not in use.
    - If the IP is clear, it is marked as assigned in the database and returned.
    - If the IP is already in use, the operation is aborted and an error is returned.
    """
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    # Fetch the first unassigned IP
    cursor.execute("SELECT ip_address FROM vlan_ips WHERE assigned = 0 LIMIT 1")
    row = cursor.fetchone()
    if row:
        ip_address = row[0]
        if is_ip_available(ip_address):
            # Mark as assigned
            cursor.execute("UPDATE vlan_ips SET assigned = 1 WHERE ip_address = ?", (ip_address,))
            conn.commit()
            conn.close()
            print(f"[INFO] Allocated IP: {ip_address}")
            return jsonify({"ip_address": ip_address}), 200
        else:
            print(f"[WARN] IP {ip_address} is already in use!")
            return jsonify({"error": "IP is already in use"}), 409
    else:
        print("[ERROR] No available IP addresses.")
        conn.close()
        return jsonify({"error": "No available IP addresses"}), 404

# =======================
# 🔄 DaemonSet Callback for VLAN Attachment
# =======================
@app.route('/vlan-attachment', methods=['POST'])
def vlan_attachment():
    """
    API Endpoint triggered by the DaemonSet when a VLAN is attached.
    - This allows the service to re-sync its IP state with the Linode environment.
    - Expected payload: { "node_ip": "<IP Address>" }
    """
    data = request.get_json()
    node_ip = data.get("node_ip")
    print(f"[INFO] VLAN attached on node: {node_ip}")
    sync_with_linode()
    return jsonify({"status": "synced"}), 200

# =======================
# 🔴 Release IP Endpoint
# =======================
@app.route('/release', methods=['POST'])
def release_ip():
    """
    API Endpoint to release an IP address back to the pool.
    - It updates the database to mark the IP as unassigned.
    - The IP is then made available for future allocation.
    """
    try:
        ip_address = request.json.get('ip_address')
        if not ip_address:
            return jsonify({"error": "IP address not provided"}), 400

        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()
        cursor.execute("SELECT ip_address FROM vlan_ips WHERE ip_address = ?", (ip_address,))
        row = cursor.fetchone()

        if row:
            cursor.execute("UPDATE vlan_ips SET assigned = 0 WHERE ip_address = ?", (ip_address,))
            conn.commit()
            conn.close()
            print(f"[INFO] Released IP: {ip_address}")
            return jsonify({"status": "IP released", "ip": ip_address}), 200
        else:
            conn.close()
            print(f"[WARN] IP address {ip_address} not found in the allocation list.")
            return jsonify({"error": f"IP address {ip_address} not found in the allocation list."}), 404
    except Exception as e:
        return jsonify({"error": str(e)}), 500

# =======================
# 🔵 Health Check Endpoint
# =======================
@app.route('/health', methods=['GET'])
def health_check():
    """
    Simple health check endpoint to verify the service is running correctly.
    """
    return jsonify({"status": "healthy"}), 200

# Initialize the database and sync with Linode
initialize_db()
sync_with_linode()

# Start the Flask application
if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
