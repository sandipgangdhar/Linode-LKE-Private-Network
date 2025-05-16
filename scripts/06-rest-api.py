from flask import Flask, jsonify, request
from flask_cors import CORS
import os
import ipaddress

app = Flask(__name__)
CORS(app)

# File path for IP allocation
IP_FILE_PATH = "/mnt/vlan-ip/vlan-ip-list.txt"

# Initialize the file if not present
if not os.path.exists(IP_FILE_PATH):
    with open(IP_FILE_PATH, 'w') as f:
        f.write("")

# =======================
# 🟢 Allocate IP Endpoint
# =======================
@app.route('/allocate', methods=['POST'])
def allocate_ip():
    try:
        # Read the requested subnet
        subnet = request.json.get('subnet')
        if not subnet:
            return jsonify({"error": "Subnet not provided"}), 400
        
        # Validate the subnet
        try:
            ip_net = ipaddress.ip_network(subnet, strict=False)
            cidr_suffix = f"/{ip_net.prefixlen}"
        except ValueError:
            return jsonify({"error": "Invalid subnet format"}), 400
        
        # Reserved IPs (first, second, and last)
        reserved_ips = {str(ip_net.network_address), str(ip_net[1]), str(ip_net[-1])}
        
        # Read the current IP list
        with open(IP_FILE_PATH, 'r+') as f:
            ip_list = f.read().splitlines()
            
            for ip in ip_net.hosts():
                candidate_ip = f"{ip}{cidr_suffix}"
                
                # Skip reserved IPs
                if candidate_ip in reserved_ips:
                    continue

                # Check if it's already allocated
                if candidate_ip not in ip_list:
                    f.write(f"{candidate_ip}\n")
                    return jsonify({"allocated_ip": candidate_ip}), 200
        
        return jsonify({"error": "No IPs available in the range"}), 500
    except Exception as e:
        return jsonify({"error": str(e)}), 500

# =======================
# 🔴 Release IP Endpoint
# =======================
@app.route('/release', methods=['POST'])
def release_ip():
    try:
        ip_address = request.json.get('ip_address')
        if not ip_address:
            return jsonify({"error": "IP address not provided"}), 400

        # Read and remove the IP address
        with open(IP_FILE_PATH, 'r') as f:
            ip_list = [line.strip() for line in f.read().splitlines()]

        # Read the reserved IP list
        with open('/mnt/vlan-ip/reserved-ips.txt', 'r') as f:
            reserved_ips = [line.strip() for line in f.read().splitlines()]

        # Strip the input IP too
        ip_address = ip_address.strip()

        # === New Logic: Prevent reserved IP release ===
        if ip_address in reserved_ips:
            return jsonify({"error": f"IP address {ip_address} is reserved and cannot be released."}), 403

        if ip_address in ip_list:
            ip_list.remove(ip_address)
            with open(IP_FILE_PATH, 'w') as f:
                f.write("\n".join(ip_list) + "\n")
            return jsonify({"status": "IP released", "ip": ip_address}), 200
        else:
            return jsonify({"error": f"IP address {ip_address} not found in the allocation list."}), 404
    except Exception as e:
        return jsonify({"error": str(e)}), 500
# =======================
# 🔵 Health Check Endpoint
# =======================
@app.route('/health', methods=['GET'])
def health_check():
    return jsonify({"status": "healthy"}), 200

# =======================
# 🚀 Start Flask Application
# =======================
if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=True)
