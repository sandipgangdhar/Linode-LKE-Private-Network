#!/bin/bash

# Configuration
LEADER_SERVICE_URL="http://vlan-leader-service.kube-system.svc.cluster.local:8080/allocate"

# Log the request
echo "[INFO] $(date) Requesting IP from Leader at $LEADER_SERVICE_URL..."

# Send HTTP POST request to the leader service
response=$(curl -s -X POST $LEADER_SERVICE_URL -H "Content-Type: application/json" -d '{}')

# Check if the response contains an allocated IP
if echo "$response" | grep -q "allocated_ip"; then
    allocated_ip=$(echo "$response" | jq -r '.allocated_ip')
    echo "[INFO] $(date) Successfully allocated IP: $allocated_ip"
    echo "$allocated_ip"
else
    echo "[ERROR] $(date) Failed to allocate IP. Response from leader: $response"
    exit 1
fi
