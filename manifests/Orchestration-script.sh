#!/bin/bash

# Orchestration Script for LKE VLAN Manager Deployment
set -e

# Define YAML file paths
STORAGE_CLASS_YAML="01-linode-storageclass.yaml"
PVC_YAML="02-vlan-ip-pvc.yaml"
RBAC_YAML="03-vlan-manager-rbac.yaml"
SCRIPTS_CONFIGMAP_YAML="04-vlan-manager-scripts-configmap.yaml"
INITIALIZER_JOB_YAML="05-vlan-ip-initializer-job.yaml"
LEADER_MANAGER_DEPLOYMENT_YAML="06-vlan-leader-manager-deployment.yaml"
VLAN_MANAGER_DAEMONSET_YAML="07-vlan-manager-daemonset.yaml"

# Functions
log() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

rollback() {
    log "Rolling back previous changes..."
    kubectl delete -f $VLAN_MANAGER_DAEMONSET_YAML --ignore-not-found=true
    kubectl delete -f $LEADER_MANAGER_DEPLOYMENT_YAML --ignore-not-found=true
    kubectl delete -f $INITIALIZER_JOB_YAML --ignore-not-found=true
    kubectl delete -f $SCRIPTS_CONFIGMAP_YAML --ignore-not-found=true
    kubectl delete -f $RBAC_YAML --ignore-not-found=true
    kubectl delete -f $PVC_YAML --ignore-not-found=true
    kubectl delete -f $STORAGE_CLASS_YAML --ignore-not-found=true
    exit 1
}

# Interactive Variable Setup
echo "Enter the Subnet (default is 172.16.0.0/12):"
read -r SUBNET
SUBNET=${SUBNET:-"172.16.0.0/12"}

echo "Enter the Route IP (default is 172.16.0.1):"
read -r ROUTE_IP
ROUTE_IP=${ROUTE_IP:-"172.16.0.1"}

echo "Enter the VLAN Label (default is Linode-AWS):"
read -r VLAN_LABEL
VLAN_LABEL=${VLAN_LABEL:-"Linode-AWS"}

# Start Orchestration
log "Starting Orchestration for VLAN Manager Deployment..."

# Step 1: Delete existing storage class if present
log "Deleting existing Linode storage class if present..."
kubectl delete storageclass linode-block-storage --ignore-not-found=true || rollback

# Step 2: Apply YAML configurations
log "Applying $STORAGE_CLASS_YAML..."
kubectl apply -f $STORAGE_CLASS_YAML || rollback

log "Applying $PVC_YAML..."
kubectl apply -f $PVC_YAML || rollback

log "Applying $RBAC_YAML..."
kubectl apply -f $RBAC_YAML || rollback

log "Applying $SCRIPTS_CONFIGMAP_YAML..."
kubectl apply -f $SCRIPTS_CONFIGMAP_YAML || rollback

# Step 3: Apply Initializer Job and wait for completion
log "Applying $INITIALIZER_JOB_YAML..."
kubectl apply -f $INITIALIZER_JOB_YAML || rollback

log "Waiting for Initializer Job to complete..."
kubectl wait --for=condition=complete job/vlan-ip-initializer -n kube-system --timeout=300s || rollback

# Step 4: Deploy Leader Manager
log "Deploying VLAN Leader Manager..."
kubectl apply -f $LEADER_MANAGER_DEPLOYMENT_YAML || rollback

# Step 5: Verify Leader is elected and IP allocation works
log "Waiting for Leader to be Ready..."
sleep 10
log "Testing IP allocation from Leader..."
curl -s -X POST http://vlan-leader-service.kube-system.svc.cluster.local:8080/allocate -H "Content-Type: application/json" -d '{}' || rollback

# Step 6: Deploy VLAN Manager DaemonSet
log "Deploying VLAN Manager DaemonSet with Environment Variables..."
kubectl apply -f $VLAN_MANAGER_DAEMONSET_YAML || rollback

log "Orchestration Completed Successfully."
