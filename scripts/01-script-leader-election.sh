#!/bin/bash

# Configuration
NAMESPACE="kube-system"
POD_NAME=$(hostname)
LEADER_ANNOTATION="vlan-manager-leader"
LOCK_DURATION="30s"
FLASK_APP=/root/scripts/06-rest-api.py
FLASK_RUN_PORT=8080

# Function to check leadership
is_leader() {
    kubectl get configmap -n $NAMESPACE $LEADER_ANNOTATION -o jsonpath="{.metadata.annotations.leader}" 2>/dev/null
}

# Attempt to become leader
attempt_leadership() {
    echo "[INFO] Attempting to become leader..."
    kubectl annotate --overwrite configmap -n $NAMESPACE $LEADER_ANNOTATION leader="$POD_NAME"
}

# Function to check if Flask is running
is_flask_running() {
    netstat -tuln | grep ":8080"  > /dev/null	
    return $?
}

# Function to clean up stale Flask process if found
cleanup_flask() {
    local flask_pid
    flask_pid=$(netstat -tulnp 2>/dev/null | grep ":8080" | awk '{print $7}' | cut -d'/' -f1)
    if [ -n "$flask_pid" ]; then
        echo "[INFO] Killing stale Flask process: $flask_pid"
        kill -9 "$flask_pid"
    fi
}

# Periodic leadership check
while true; do
    current_leader=$(is_leader)

    if [ -z "$current_leader" ]; then
        echo "[INFO] No leader found. Attempting to become leader..."
        attempt_leadership
        current_leader=$(is_leader) # Re-fetch the leader info after attempting

        if [ "$current_leader" == "$POD_NAME" ]; then
            echo "[INFO] Successfully became the leader: $POD_NAME"
        else
            echo "[INFO] Failed to become leader. Current leader is $current_leader"
        fi
    fi

    if [ "$current_leader" == "$POD_NAME" ]; then
        echo "[INFO] I am the leader: $POD_NAME"
	    # Check if Flask is already running
	    if is_flask_running; then
		    echo "[INFO] Flask is already running on port 8080, skipping start..."
	    else	
		    echo "[INFO] Starting Flask server on port 8080..."
		    cleanup_flask
    	    # Start REST API for IP Allocation
		    nohup python3 /tmp/06-rest-api.py > /tmp/flask.log 2>&1 &
		    echo "[INFO] Flask server started with PID: $!"
	    fi
    else
        echo "[INFO] Current leader is $current_leader. Sleeping for $LOCK_DURATION..."
    fi
    sleep 10
done 
