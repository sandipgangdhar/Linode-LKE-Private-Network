"""
Test Script for 06-rest-api.py

This script is responsible for validating all the API endpoints of the 06-rest-api service.
It performs:

1️⃣ Health Check
2️⃣ IP Allocation and Verification
3️⃣ IP Release and Verification
4️⃣ VLAN Attachment Simulation

Usage:
    python3 test-rest-api.py

Make sure the 06-rest-api.py is running before executing this test.

© Linode-LKE-Private-Network | Developed by Sandip Gangdhar | 2025
"""

import requests
import json

# Base URL of the running API
target_url = "http://localhost:5000"

# ===========================
# 🟢 Health Check
# ===========================
print("[TEST] Checking health status of the API...")
response = requests.get(f"{target_url}/health")
assert response.status_code == 200, "[FAILED] Health check did not pass."
print("[SUCCESS] API is healthy.")

# ===========================
# 🟢 Allocate IP
# ===========================
print("[TEST] Allocating an IP address...")
response = requests.post(f"{target_url}/allocate-ip")
allocated_ip = response.json().get('ip_address')
assert response.status_code == 200, "[FAILED] IP allocation failed."
print(f"[SUCCESS] IP allocated successfully: {allocated_ip}")

# ===========================
# 🔴 Release IP
# ===========================
print("[TEST] Releasing the IP address...")
release_data = {"ip_address": allocated_ip}
response = requests.post(f"{target_url}/release", json=release_data)
assert response.status_code == 200, "[FAILED] IP release failed."
print(f"[SUCCESS] IP released successfully: {allocated_ip}")

# ===========================
# 🔄 VLAN Attachment Simulation
# ===========================
print("[TEST] Simulating VLAN attachment...")
attachment_data = {"node_ip": "192.168.1.10"}
response = requests.post(f"{target_url}/vlan-attachment", json=attachment_data)
assert response.status_code == 200, "[FAILED] VLAN attachment sync failed."
print("[SUCCESS] VLAN attachment simulated successfully.")

print("\n===============================")
print("[ALL TESTS PASSED SUCCESSFULLY]")
print("===============================\n")
