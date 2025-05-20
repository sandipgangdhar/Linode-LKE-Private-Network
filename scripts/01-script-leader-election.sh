# 01-script-leader-election.sh
# 
# This shell script handles leader election among VLAN manager instances
# running in a Linode LKE cluster. It determines which instance is the leader
# responsible for managing VLAN IP assignments and coordination.
# 
# -----------------------------------------------------
# 📝 Parameters:
# 
# 1️⃣ LEADER_FILE            - File path to store leader identity.
# 2️⃣ NODE_NAME              - The name of the current node.
# 3️⃣ NAMESPACE              - Kubernetes namespace where the pods are running.
# 4️⃣ APP_LABEL              - Label selector to find all relevant pods.
# 
# -----------------------------------------------------
# 🔄 Usage:
# 
# - This script is executed as part of the DaemonSet startup.
# - It checks the list of running pods, sorts by name, and elects the first
#   alphabetically as the leader.
# - If the node is the leader, it writes its identity to the LEADER_FILE.
# 
# -----------------------------------------------------
# 📌 Best Practices:
# 
# - Ensure the namespace and labels are configured correctly in the DaemonSet.
# - Monitor the logs to verify proper leader election and failover.
# - Use health checks to verify the leader's status before critical operations.
# 
# -----------------------------------------------------
# 🖋️ Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
# 
# © Linode-LKE-Private-Network | Developed by Sandip Gangdhar | 2025
#!/bin/bash

# === Environment Variables ===
NAMESPACE="kube-system"
POD_NAME=$(hostname)
LEADER_ANNOTATION="vlan-manager-leader"
LOCK_DURATION="30s"
FLASK_APP=/root/scripts/06-rest-api.py
FLASK_RUN_PORT=8080

# === Function to Log Events ===
log() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log "🔄 Starting Leader Election Process..."

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
