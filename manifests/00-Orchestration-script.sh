#!/bin/bash

set -e

# === Orchestration Script ===
# This script automates the deployment of VLAN Manager and associated services in Kubernetes.

# === Cleanup Function on Failure ===
cleanup() {
    echo "❌ Deployment failed. Performing cleanup..."
    
    echo "🧹 Cleaning up Initializer Job..."
    kubectl delete job vlan-ip-initializer -n kube-system --ignore-not-found && echo "✅ Initializer Job deleted."
    
    echo "🧹 Cleaning up VLAN Leader Manager Deployment..."
    kubectl delete deployment vlan-leader-manager -n kube-system --ignore-not-found && echo "✅ VLAN Leader Manager Deployment deleted."
    
    echo "🧹 Cleaning up VLAN Manager DaemonSet..."
    kubectl delete daemonset vlan-manager -n kube-system --ignore-not-found && echo "✅ VLAN Manager DaemonSet deleted."
    
    echo "🧹 Cleaning up PersistentVolumeClaim..."
    kubectl delete pvc vlan-ip-pvc -n kube-system --ignore-not-found && echo "✅ PersistentVolumeClaim deleted."
    
    echo "🧹 Cleaning up ConfigMaps..."
    kubectl delete configmap vlan-manager-scripts -n kube-system --ignore-not-found && echo "✅ vlan-manager-scripts ConfigMap deleted."
    kubectl delete configmap linode-cli-config -n kube-system --ignore-not-found && echo "✅ linode-cli-config ConfigMap deleted."
    kubectl delete configmap vlan-manager-config -n kube-system --ignore-not-found && echo "✅ vlan-manager-config ConfigMap deleted."
    
    echo "✅ Cleanup complete."
}

# === Argument Parsing ===
if [[ "$1" == "--cleanup" ]]; then
    echo "🧹 Cleanup flag detected. Initiating cleanup..."
    cleanup
    exit 0
fi

trap cleanup EXIT

# === Step 1: Apply StorageClass ===
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

# === Step 4: Apply ConfigMaps ===
echo "✅ Applying ConfigMap for VLAN Manager Scripts..."
kubectl apply -f 04-vlan-manager-scripts-configmap.yaml || exit 1

echo "✅ Applying ConfigMap for VLAN Manager Configuration..."
kubectl apply -f 00-vlan-manager-configmap.yaml || exit 1

# === Step 5: Apply Initializer Job ===
echo "🚀 Launching VLAN IP Initializer Job..."
kubectl apply -f 05-vlan-ip-initializer-job.yaml || exit 1

# Wait for Job to appear in Kubernetes
echo "⏳ Waiting for Initializer Job to be registered in Kubernetes..."
for i in {1..10}; do
    if kubectl get job vlan-ip-initializer -n kube-system &>/dev/null; then
        echo "✅ Initializer Job found."
        break
    fi
    echo "🔄 Job not found yet. Retrying in 5 seconds... ($i/10)"
    sleep 5
done

# Wait for Job to complete
echo "⏳ Waiting for Initializer Job to complete..."
kubectl wait --for=condition=complete --timeout=600s job/vlan-ip-initializer -n kube-system

# Wait for PVC to be detached
echo "⏳ Waiting for PersistentVolumeClaim to be available..."
for i in {1..20}; do
    PVC_STATUS=$(kubectl describe pvc vlan-ip-pvc -n kube-system | grep "Used By:" | awk '{print $3}')
    
    if [ "$PVC_STATUS" == "<none>" ]; then
        echo "✅ PersistentVolumeClaim is now available for use."
        break
    else
        echo "🔄 PVC still attached to $PVC_STATUS... retrying ($i/20)"
        sleep 10
    fi
done

# === Step 6: Deploy Leader Manager Deployment ===
echo "🚀 Deploying VLAN Leader Manager..."
kubectl apply -f 06-vlan-leader-manager-deployment.yaml || exit 1

# Wait for deployment to be ready
echo "⏳ Waiting for VLAN Leader Manager to be ready..."
kubectl rollout status deployment/vlan-leader-manager -n kube-system

# === Check if port 8080 is open and healthy ===
echo "🔎 Checking if port 8080 is available on vlan-leader-manager..."
LEADER_POD=$(kubectl get pods -n kube-system -l app=vlan-leader-manager -o jsonpath='{.items[0].metadata.name}')

for i in {1..10}; do
    if kubectl exec -n kube-system $LEADER_POD -- curl -s http://localhost:8080/health &> /dev/null; then
        echo "✅ VLAN Leader Manager is healthy and responding."
        break
    else
        echo "🔄 Waiting for VLAN Leader Manager to become healthy... ($i/10)"
        sleep 6
    fi
done

if [ $i -eq 10 ]; then
    echo "❌ VLAN Leader Manager failed to become healthy. Capturing logs..."
    kubectl logs -n kube-system $LEADER_POD > vlan-leader-manager-logs.txt
    echo "💡 Logs saved to vlan-leader-manager-logs.txt"
    exit 1
fi

echo "✅ VLAN Leader Manager is up and running."

# === Step 7: Deploy VLAN Manager DaemonSet ===
echo "🚀 Deploying VLAN Manager DaemonSet..."
kubectl apply -f 07-vlan-manager-daemonset.yaml || exit 1

# Wait for DaemonSet rollout
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

echo "🎉 Orchestration Complete! VLAN Manager is fully operational."

trap - EXIT
