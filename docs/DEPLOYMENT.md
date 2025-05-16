# Deployment Guide: Linode LKE VLAN Orchestration

This guide provides step-by-step instructions for deploying the Linode LKE VLAN Orchestration solution.

---

## 📌 **Prerequisites:**  
1. Kubernetes cluster running on **Linode LKE**  
2. `kubectl` configured with cluster access  
3. `linode-cli` configured with your API token:  

    ```bash
    linode-cli configure
    ```

4. StorageClass created on Linode for Persistent Volumes  

---

## 🚀 **Deployment Steps:**  

1. **Clone the Repository:**  
    ```bash
    git clone https://github.com/sandipgangdhar/Linode-LKE-Private-Network.git
    cd Linode-LKE-Private-Network
    ```

2. **Make Orchestration Script Executable:**  
    ```bash
    chmod +x 00-Orchestration-Script.sh
    ```

3. **Run the Orchestration Script:**  
    ```bash
    ./00-Orchestration-Script.sh
    ```

4. **Monitor the Deployment:**  
    ```bash
    kubectl get pods -n kube-system
    ```

---

## 🔎 **Validation:**  

1. **Check VLAN Leader Manager:**  
    ```bash
    kubectl rollout status deployment/vlan-leader-manager -n kube-system
    ```

2. **Check VLAN Manager DaemonSet:**  
    ```bash
    kubectl rollout status daemonset/vlan-manager -n kube-system
    ```

3. **Check IP Allocation List:**  
    ```bash
    kubectl exec -n kube-system <leader-pod-name> -- cat /mnt/vlan-ip/vlan-ip-list.txt
    ```

4. **Verify Routes:**  
    ```bash
    ip route show | grep <DEST_SUBNET>
    ```

---
## 🛠️ Cleanup:
To completely remove the deployment, execute the following command:

    ./00-Orchestration-script.sh --cleanup

---

## ⚠️ Troubleshooting:
If you encounter any issues during deployment, follow the steps below to diagnose and fix the problem:

---

### 1️⃣ VLAN Leader Manager is not healthy:
- **Check the logs for errors:**  
    kubectl logs -f deployment/vlan-leader-manager -n kube-system

- **Verify if the pod is running:**  
    kubectl get pods -n kube-system | grep vlan-leader-manager

- **Restart the deployment if necessary:**  
    kubectl rollout restart deployment/vlan-leader-manager -n kube-system

---

### 2️⃣ VLAN Manager DaemonSet is not ready:
- **Check the logs for individual pods:**  
    kubectl logs -f daemonset/vlan-manager -n kube-system

- **Check if all pods are running:**  
    kubectl get pods -n kube-system | grep vlan-manager

- **Restart the DaemonSet if required:**  
    kubectl rollout restart daemonset/vlan-manager -n kube-system

---

### 3️⃣ IP allocation is not happening correctly:
- **Check the VLAN Leader Manager logs:**  
    kubectl logs -f deployment/vlan-leader-manager -n kube-system

- **Verify the contents of the IP list:**  
    kubectl exec -n kube-system <leader-pod-name> -- cat /mnt/vlan-ip/vlan-ip-list.txt

- **Check if the IP exists or is marked as reserved:**  
    - Ensure the IP is not part of the reserved list (first two and last IP of the subnet).

---

### 4️⃣ PersistentVolumeClaim (PVC) issues:
- **Check the PVC status:**  
    kubectl describe pvc vlan-ip-pvc -n kube-system

- **If PVC is stuck in pending or not attaching:**  
    kubectl get pv | grep vlan-ip-pvc

- **Check for logs of the associated pod that mounted the PVC:**  
    kubectl logs -f pod/<pod-name> -n kube-system

---

### 5️⃣ Route is not getting added to eth1:
- **Verify if the route exists:**  
    ip route show | grep <DEST_SUBNET>

- **Manually add the route if missing:**  
    ip route add <DEST_SUBNET> via <ROUTE_IP> dev eth1

- **Check for errors in `/tmp/02-script-vlan-attach.sh` logs:**  
    cat /tmp/vlan-attach.log

---

### 6️⃣ General Debugging Commands:
- **Get all pods and their status:**  
    kubectl get pods -n kube-system

- **Check logs for a specific pod:**  
    kubectl logs -f pod/<pod-name> -n kube-system

- **Describe the pod for detailed info:**  
    kubectl describe pod <pod-name> -n kube-system

- **Check if Linode CLI is configured properly:**  
    linode-cli linodes list

---

If the issue persists, please collect the logs and reach out with the logs for further analysis.
