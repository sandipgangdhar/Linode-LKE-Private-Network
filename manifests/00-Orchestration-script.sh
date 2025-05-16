#!/bin/bash

set -e

# === Orchestration Script ===
# This script automates the deployment of VLAN Manager and associated services in Kubernetes.

# === Cleanup Function on Failure ===
cleanup() {
    echo "❌ Deployment failed. Performing cleanup..."
    echo "🧹 Cleaning up Initializer Job..."
kubectl delete job vlan-ip-initializer --ignore-not-found && echo "✅ Initializer Job deleted."
    echo "🧹 Cleaning up VLAN Leader Manager Deployment..."
kubectl delete deployment vlan-leader-manager -n kube-system --ignore-not-found && echo "✅ VLAN Leader Manager Deployment deleted."
    echo "🧹 Cleaning up VLAN Manager DaemonSet..."
kubectl delete daemonset vlan-manager -n kube-system --ignore-not-found && echo "✅ VLAN Manager DaemonSet deleted."
    echo "🧹 Cleaning up PersistentVolumeClaim..."
kubectl delete pvc vlan-ip-pvc --ignore-not-found && echo "✅ PersistentVolumeClaim deleted."
    echo "🧹 Cleaning up ConfigMaps..."
kubectl delete configmap vlan-manager-scripts --ignore-not-found && echo "✅ vlan-manager-scripts ConfigMap deleted."
    kubectl delete configmap linode-cli-config --ignore-not-found && echo "✅ linode-cli-config ConfigMap deleted."
    echo "✅ Cleanup complete."
}

trap cleanup EXIT

# === Step 1: Delete existing StorageClass ===
echo "🔄 Checking for existing Linode Block StorageClass..."

if kubectl get storageclass linode-block-storage &> /dev/null; then
    echo "✅ linode-block-storage already exists. Skipping creation."
else
    echo "🚀 Creating Linode Block StorageClass..."
    kubectl apply -f 01-linode-storageclass.yaml || exit 1
    echo "✅ linode-block-storage created successfully."
fi

# === Step 2: Apply PersistentVolumeClaim (PVC) ===
echo "✅ Applying PersistentVolumeClaim for VLAN IP storage..."
kubectl apply -f 02-vlan-ip-pvc.yaml || exit 1

# === Step 3: Apply RBAC for VLAN Manager ===
echo "✅ Applying RBAC for VLAN Manager..."
kubectl apply -f 03-vlan-manager-rbac.yaml || exit 1

# === Step 4: Apply ConfigMap for VLAN Manager Scripts ===
echo "✅ Applying ConfigMap for VLAN Manager Scripts..."
kubectl apply -f 04-vlan-manager-scripts-configmap.yaml || exit 1

# === Step 5: Apply Initializer Job ===
echo "🚀 Launching VLAN IP Initializer Job..."
kubectl apply -f 05-vlan-ip-initializer-job.yaml || exit 1

# Wait for Job to appear in Kubernetes
echo "⏳ Waiting for Initializer Job to be registered in Kubernetes..."
MAX_RETRIES=10
RETRY_COUNT=0
while ! kubectl get job vlan-ip-initializer -n kube-system &>/dev/null; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "❌ Initializer Job not found after $MAX_RETRIES attempts. Exiting..."
        exit 1
    fi
    echo "🔄 Job not found yet. Retrying in 5 seconds... ($RETRY_COUNT/$MAX_RETRIES)"
    sleep 6
done

# Wait for Job to complete
echo "⏳ Waiting for Initializer Job to complete..."
echo "⏳ Waiting for Initializer Job to complete..."
kubectl wait --for=condition=complete --timeout=600s job/vlan-ip-initializer -n kube-system

# Wait for PV to be available
echo "⏳ Waiting for PersistentVolume to become available..."
RETRIES=0
while [ $RETRIES -lt 20 ]; do
    PV_STATUS=$(kubectl get pv | grep vlan-ip-pvc | awk '{print $5}')
    if [ "$PV_STATUS" == "Available" ]; then
        echo "✅ PersistentVolume is now available."
        break
    fi
    echo "🔄 Waiting for PV to be released... ($RETRIES/20)"
    RETRIES=$((RETRIES + 1))
    sleep 10
done

if [ $RETRIES -eq 20 ]; then
    echo "❌ PersistentVolume did not become available. Exiting..."
    exit 1
fi
 || exit 1

echo "✅ VLAN IP Initializer Job completed."

# === Step 6: Deploy Leader Manager Deployment ===
echo "🚀 Deploying VLAN Leader Manager..."
kubectl apply -f 06-vlan-leader-manager-deployment.yaml || exit 1

# Wait for deployment to be ready
echo "⏳ Waiting for VLAN Leader Manager to be ready..."
kubectl rollout status deployment/vlan-leader-manager -n kube-system

# === Check if port 8080 is open and healthy ===
echo "🔎 Checking if port 8080 is available on vlan-leader-manager..."
LEADER_POD=$(kubectl get pods -n kube-system -l app=vlan-leader-manager -o jsonpath='{.items[0].metadata.name}')
MAX_RETRIES=10
COUNT=0
while [ $COUNT -lt $MAX_RETRIES ]; do
    if kubectl exec -n kube-system $LEADER_POD -- curl -s http://localhost:8080/health &> /dev/null; then
        echo "✅ VLAN Leader Manager is healthy and responding."
        break
    else
        echo "🔄 Waiting for VLAN Leader Manager to become healthy... ($COUNT/$MAX_RETRIES)"
        sleep 6
    fi
    COUNT=$((COUNT + 1))
done

if [ $COUNT -eq $MAX_RETRIES ]; then
    echo "❌ VLAN Leader Manager failed to become healthy. Exiting..."
    exit 1
fi
 || exit 1

echo "✅ VLAN Leader Manager is up and running."

# === Step 7: Deploy VLAN Manager DaemonSet ===
echo "🚀 Deploying VLAN Manager DaemonSet..."
kubectl apply -f 07-vlan-manager-daemonset.yaml || exit 1

# Wait for DaemonSet pods to be ready
echo "⏳ Waiting for VLAN Manager DaemonSet to be ready..."
kubectl rollout status daemonset/vlan-manager -n kube-system

# === Log command hints for DaemonSet Pods ===
echo "🔎 Fetching VLAN Manager Pods..."
PODS=$(kubectl get pods -n kube-system -l app=vlan-manager -o jsonpath='{.items[*].metadata.name}')

if [ -z "$PODS" ]; then
    echo "❌ No VLAN Manager pods found. Exiting..."
    exit 1
fi

echo "✅ VLAN Manager DaemonSet is fully deployed."
echo "🔍 You can monitor the logs using the following commands:"
for pod in $PODS; do
    echo "kubectl logs -f pod/$pod -n kube-system"
done
 || exit 1

echo "✅ VLAN Manager DaemonSet is fully deployed."

echo "🎉 Orchestration Complete! VLAN Manager is fully operational."

trap - EXIT
