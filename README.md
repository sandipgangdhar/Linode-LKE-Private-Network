# Linode-LKE-Private-Network

This repository provides an automated solution for setting up a private VLAN-based networking environment on a Linode Kubernetes Engine (LKE) cluster. It facilitates seamless private IP allocation, VLAN attachment, and route management between Linode and AWS or other private subnets.

## Features:

* **VLAN Attachment:** Automatically attaches VLAN interfaces to LKE worker nodes.
* **Private IP Allocation:** Manages private IP allocation using a leader election mechanism for synchronization.
* **Route Management:** Pushes custom routes to worker nodes upon VLAN attachment.
* **High Availability:** Leader election mechanism ensures failover and consistency in IP allocation.

## Architecture:

1. **Storage Class & PVC** - Creates the necessary storage class and persistent volume claim for storing IP addresses.
2. **RBAC Policies** - Ensures appropriate permissions for the pods to perform network operations.
3. **ConfigMaps & Scripts** - Deploys necessary scripts and configurations.
4. **VLAN Initializer Job** - Initializes the IP list and reserved IPs for VLAN.
5. **Leader Manager Deployment** - Manages leader election and IP allocation.
6. **VLAN Manager DaemonSet** - Manages VLAN attachment and route pushing to worker nodes.

## Deployment Steps:

1. Apply the storage class:

   ```bash
   kubectl apply -f 01-linode-storageclass.yaml
   ```

2. Apply the PVC:

   ```bash
   kubectl apply -f 02-vlan-ip-pvc.yaml
   ```

3. Apply RBAC policies:

   ```bash
   kubectl apply -f 03-vlan-manager-rbac.yaml
   ```

4. Apply ConfigMaps:

   ```bash
   kubectl apply -f 04-vlan-manager-scripts-configmap.yaml
   ```

5. Initialize VLAN IP list:

   ```bash
   kubectl apply -f 05-vlan-ip-initializer-job.yaml
   ```

6. Deploy the Leader Manager:

   ```bash
   kubectl apply -f 06-vlan-leader-manager-deployment.yaml
   ```

7. Deploy the VLAN Manager DaemonSet:

   ```bash
   kubectl apply -f 07-vlan-manager-daemonset.yaml
   ```

## Verification:

* **Check Leader Status:**

  ```bash
  kubectl get configmap vlan-manager-leader -n kube-system -o yaml
  ```

* **Verify IP Allocation:**

  ```bash
  curl -X POST http://<leader_pod_ip>:8080/allocate -H "Content-Type: application/json" -d '{}'
  ```

* **Verify VLAN Attachment:**

  ```bash
  linode-cli linodes config-view <LINODE_ID> <CONFIG_ID> --json | jq
  ```

* **Verify Route on Worker Node:**

  ```bash
  ip route show
  ```

---

## Orchestration:

The orchestration is handled via `orchestration.sh` which automates all the steps above.

---
