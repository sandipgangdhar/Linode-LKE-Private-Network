# Troubleshooting Guide: Linode LKE VLAN Orchestration

This document covers common issues and their resolutions during the deployment and operation of the Linode LKE VLAN Orchestration.

---

## 🔍 **Common Issues and Fixes:**

### 1️⃣ **VLAN Leader Manager Pod not Starting:**

- **Check Logs:**
    ```bash
    kubectl logs -f deployment/vlan-leader-manager -n kube-system
    ```

- **Possible Causes:**
    - Missing `linode-cli` configuration
    - API token not configured
    - Incorrect Kubernetes cluster configuration

- **Fix:** Ensure `linode-cli` is configured properly:
    ```bash
    linode-cli configure
    ```

---

### 2️⃣ **VLAN Manager DaemonSet Pods not Ready:**

- **Check Logs:**
    ```bash
    kubectl logs -f daemonset/vlan-manager -n kube-system
    ```

- **Possible Causes:**
    - Network interfaces not configured
    - Routes not pushed successfully

- **Fix:** Re-run the `00-Orchestration-Script.sh` and monitor logs.

---

### 3️⃣ **IP Allocation Failing:**

- **Check Leader Pod Logs:**
    ```bash
    kubectl logs -f <leader-pod-name> -n kube-system
    ```

- **Possible Causes:**
    - IP Range exhausted
    - VLAN Leader Manager not running

- **Fix:** Validate the IP allocation list:
    ```bash
    kubectl exec -n kube-system <leader-pod-name> -- cat /mnt/vlan-ip/vlan-ip-list.txt
    ```

---

### 4️⃣ **PersistentVolumeClaim (PVC) Not Available:**

- **Check PVC Status:**
    ```bash
    kubectl describe pvc vlan-ip-pvc -n kube-system
    ```

- **Fix:** Ensure that the initializer job has finished and the PV is released.

---

### 5️⃣ **VPN Tunnel Connectivity Issues:**

- **Check Routes:**
    ```bash
    ip route show | grep <DEST_SUBNET>
    ```

- **Fix:** Verify the VPN tunnel configuration and routing policies.

---

## 🚀 **Need More Help?**

If the issues persist, please refer to the documentation or reach out to the project maintainers.

