#!/bin/bash

set -e

# === Orchestration Script ===
# This script automates the deployment of VLAN Manager and associated services in Kubernetes.

# === Cleanup Function on Failure ===
cleanup() {
    echo "❌ Deployment failed. Performing cleanup..."
    
    echo "🧹 Cleaning up Initializer Job..."
    kubectl delete job vlan-ip-initializer -n kube-system --ignore-not-found && echo "✅ Initializer Job deleted."
    
    echo "🧹 Cleaning up VLAN Manager DaemonSet..."
    kubectl delete daemonset vlan-manager -n kube-system --ignore-not-found && echo "✅ VLAN Manager DaemonSet deleted."
    
    echo "🧹 Cleaning up ConfigMaps..."
    kubectl delete configmap vlan-manager-scripts -n kube-system --ignore-not-found && echo "✅ vlan-manager-scripts ConfigMap deleted."
    kubectl delete configmap linode-cli-config -n kube-system --ignore-not-found && echo "✅ linode-cli-config ConfigMap deleted."
    kubectl delete configmap vlan-manager-config -n kube-system --ignore-not-found && echo "✅ vlan-manager-config ConfigMap deleted."
    
    echo "🧹 Cleaning up etcd StatefulSet and Services..."
    kubectl delete statefulset etcd -n kube-system --ignore-not-found && echo "✅ etcd StatefulSet deleted."
    kubectl delete service etcd -n kube-system --ignore-not-found && echo "✅ etcd Service deleted."
    kubectl delete service etcd-headless -n kube-system --ignore-not-found && echo "✅ etcd Headless Service deleted."
    kubectl delete pvc -l app=etcd -n kube-system --ignore-not-found && echo "✅ etcd PVCs deleted."

    echo "🧹 Cleaning up VLAN IP CONTROLLER Deployment..."
    kubectl delete deployment vlan-ip-controller -n kube-system --ignore-not-found && echo "✅ VLAN Leader Manager Deployment deleted."
    kubectl delete service vlan-ip-controller-service -n kube-system --ignore-not-found && echo "✅ VLAN IP CONTROLLER service deleted."

    echo "✅ Cleanup complete."
}

# === Argument Parsing ===
if [[ "$1" == "--cleanup" ]]; then
    echo "🧹 Cleanup flag detected. Initiating cleanup..."
    cleanup
    exit 0
fi

trap cleanup EXIT

# === Function to log messages ===
log() {
    echo -e "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# === Function to get Kubernetes node count ===
get_worker_node_count() {
    kubectl get nodes --no-headers | wc -l
}

# === Decide etcd deployment type based on node count ===
deploy_etcd_cluster() {
    NODE_COUNT=$(get_worker_node_count)
    log "📊 Detected $NODE_COUNT worker node(s) in the cluster."

    if [ "$NODE_COUNT" -lt 3 ]; then
        log "🚦 Node count <$NODE_COUNT> is less than 3. Deploying single-node etcd setup (standalone mode)..."
        kubectl apply -f 08-etcd-StatefulSet-1node.yaml
    else
        log "🚀 Node count is $NODE_COUNT. Deploying 3-node etcd setup (HA mode)..."
        kubectl apply -f 08-etcd-StatefulSet-3node.yaml
    fi
}

# === setting the etcd endpoint based on node count ===
Apply_Initializer_Job() {
    NODE_COUNT=$(get_worker_node_count)
    log "📊 Detected $NODE_COUNT worker node(s) in the cluster."

    if [ "$NODE_COUNT" -lt 3 ]; then
        log "🚦 Node count <$NODE_COUNT> is less than 3 setting the etcd endpoint accordingly..."
        export ETCD_ENDPOINTS="http://etcd-0.etcd.kube-system.svc.cluster.local:2379"
        envsubst '${ETCD_ENDPOINTS}' < 05-vlan-ip-initializer-job.yaml | kubectl apply -f -
        unset ETCD_ENDPOINTS
    else
        log "🚀 Node count is $NODE_COUNT setting the etcd endpoint accordingly..."
        export ETCD_ENDPOINTS="http://etcd-0.etcd.kube-system.svc.cluster.local:2379,http://etcd-1.etcd.kube-system.svc.cluster.local:2379,http://etcd-2.etcd.kube-system.svc.cluster.local:2379"
        envsubst '${ETCD_ENDPOINTS}' < 05-vlan-ip-initializer-job.yaml | kubectl apply -f -
        unset ETCD_ENDPOINTS
    fi
}

# === setting the etcd endpoint in vlan ip controller deployment based on node count ===
Apply_etcd_endpoint_vlan_ip_controller_deployment() {
    NODE_COUNT=$(get_worker_node_count)
    log "📊 Detected $NODE_COUNT worker node(s) in the cluster."

    if [ "$NODE_COUNT" -lt 3 ]; then
        log "🚦 Node count <$NODE_COUNT> is less than 3 setting the etcd endpoint accordingly..."
        export ETCD_ENDPOINTS="http://etcd-0.etcd.kube-system.svc.cluster.local:2379"
        envsubst '${ETCD_ENDPOINTS}' < 06-vlan-ip-controller-deployment.yaml | kubectl apply -f -
        unset ETCD_ENDPOINTS
    else
        log "🚀 Node count is $NODE_COUNT setting the etcd endpoint accordingly..."
        export ETCD_ENDPOINTS="http://etcd-0.etcd.kube-system.svc.cluster.local:2379,http://etcd-1.etcd.kube-system.svc.cluster.local:2379,http://etcd-2.etcd.kube-system.svc.cluster.local:2379"
        envsubst '${ETCD_ENDPOINTS}' < 06-vlan-ip-controller-deployment.yaml | kubectl apply -f -
        unset ETCD_ENDPOINTS
    fi
}

# === setting the etcd endpoint in vlan-manager daemonset based on node count ===
Create_vlan_manager_daemonset() {
    NODE_COUNT=$(get_worker_node_count)
    log "📊 Detected $NODE_COUNT worker node(s) in the cluster."

    if [ "$NODE_COUNT" -lt 3 ]; then
        log "🚦 Node count <$NODE_COUNT> is less than 3 setting the etcd endpoint accordingly..."
        export ETCD_ENDPOINTS="http://etcd-0.etcd.kube-system.svc.cluster.local:2379"
        envsubst '${ETCD_ENDPOINTS}' < 07-vlan-manager-daemonset.yaml | kubectl apply -f -
        unset ETCD_ENDPOINTS
    else
        log "🚀 Node count is $NODE_COUNT setting the etcd endpoint accordingly..."
        export ETCD_ENDPOINTS="http://etcd-0.etcd.kube-system.svc.cluster.local:2379,http://etcd-1.etcd.kube-system.svc.cluster.local:2379,http://etcd-2.etcd.kube-system.svc.cluster.local:2379"
        envsubst '${ETCD_ENDPOINTS}' < 07-vlan-manager-daemonset.yaml | kubectl apply -f -
        unset ETCD_ENDPOINTS
    fi
}

# === Step 1: Apply StorageClass ===
echo "🔄 Checking for existing Linode Block StorageClass..."
if kubectl get storageclass linode-block-storage &> /dev/null; then
    echo "✅ linode-block-storage already exists. Skipping creation."
else
    echo "🚀 Creating Linode Block StorageClass..."
    kubectl apply -f 01-linode-storageclass.yaml || exit 1
    echo "✅ linode-block-storage created successfully."
fi

# === Step 2: Apply RBAC for VLAN Manager ===
echo "✅ Applying RBAC for VLAN Manager..."
kubectl apply -f 03-vlan-manager-rbac.yaml || exit 1

# === Step 3: Apply ConfigMaps ===
echo "✅ Applying ConfigMap for VLAN Manager Scripts..."
kubectl apply -f 04-vlan-manager-scripts-configmap.yaml || exit 1

echo "✅ Applying ConfigMap for VLAN Manager Configuration..."
kubectl apply -f 00-vlan-manager-configmap.yaml || exit 1

# === Step 4: Creating ETCD deployment ===
echo "✅ ETCD deployment initiated based on node count."
deploy_etcd_cluster

echo "⏳ Waiting for etcd pods to be registered in Kubernetes..."
for i in {1..10}; do
    etcd_pods=$(kubectl get pods -n kube-system -l app=etcd --no-headers 2>/dev/null | wc -l)
    if [ "$etcd_pods" -ge 1 ]; then
        echo "✅ etcd pods found: $etcd_pods"
        break
    fi
    echo "🔄 etcd pods not found yet. Retrying in 5 seconds... ($i/10)"
    sleep 10
done

echo "⏳ Waiting for all etcd pods to become Ready..."
for i in {1..24}; do
    not_ready=$(kubectl get pods -n kube-system -l app=etcd --field-selector=status.phase!=Running --no-headers | wc -l)
    ready_count=$(kubectl get pods -n kube-system -l app=etcd --field-selector=status.phase=Running --no-headers | grep '1/1' | wc -l)
    total=$(kubectl get pods -n kube-system -l app=etcd --no-headers 2>/dev/null | wc -l)
    
    if [ "$total" -eq "$ready_count" ] && [ "$total" -gt 0 ]; then
        echo "✅ All etcd pods are Ready."
        break
    fi

    echo "🔄 etcd pods not ready yet. Retrying in 5 seconds... ($i/24)"
    sleep 10
done

# === Step 5: Apply Initializer Job ===
echo "🚀 Launching VLAN IP Initializer Job..."
Apply_Initializer_Job

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

# === Step 6: Deploy Leader Manager Deployment ===
echo "🚀 Deploying VLAN Leader Manager..."
Apply_etcd_endpoint_vlan_ip_controller_deployment

# Wait for deployment to be ready
echo "⏳ Waiting for VLAN Leader Manager to be ready..."
kubectl rollout status deployment/vlan-ip-controller -n kube-system

# === Check if port 8080 is open and healthy ===
echo "🔎 Checking if port 8080 is available on vlan-ip-controller..."
LEADER_POD=$(kubectl get pods -n kube-system -l app=vlan-ip-controller -o jsonpath='{.items[0].metadata.name}')

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
    kubectl logs -n kube-system $LEADER_POD > vlan-ip-controller-logs.txt
    echo "💡 Logs saved to vlan-ip-controller-logs.txt"
    exit 1
fi

# === Step 7: Deploy VLAN Manager DaemonSet ===
echo "🚀 Deploying VLAN Manager DaemonSet..."
Create_vlan_manager_daemonset

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

echo "✅ VLAN Leader Manager is up and running."

echo "🎉 Orchestration Complete! VLAN Manager is fully operational."

trap - EXIT
