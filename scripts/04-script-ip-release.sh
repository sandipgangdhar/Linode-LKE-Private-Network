#!/bin/bash

# Configuration
LEADER_SERVICE_URL="http://vlan-leader-service.kube-system.svc.cluster.local:8080/release"

# Check if IP is provided
if [ -z "$1" ]; then
    echo "[ERROR] $(date) No IP address provided for release."
    exit 1
fi

IP_TO_RELEASE="$1"

# Log the release request
echo "[INFO] $(date) Releasing IP $IP_TO_RELEASE to Leader at $LEADER_SERVICE_URL..."

# Send HTTP POST request to the leader service to release the IP
response=$(curl -s -X POST $LEADER_SERVICE_URL -H "Content-Type: application/json" -d "{\"ip\": \"$IP_TO_RELEASE\"}")

# Check if the response contains the released IP
if echo "$response" | grep -q "released_ip"; then
    released_ip=$(echo "$response" | jq -r '.released_ip')
    echo "[INFO] $(date) Successfully released IP: $released_ip"
    exit 0
else
    echo "[ERROR] $(date) Failed to release IP. Response from leader: $response"
    exit 1
fi
