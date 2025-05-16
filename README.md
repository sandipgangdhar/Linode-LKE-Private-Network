# Linode LKE VLAN Manager Solution

## Overview

This solution enables **private networking** for Linode Kubernetes Engine (LKE) clusters using **VLANs** and a **Site-to-Site IPsec VPN**. By integrating VLAN support directly with LKE, workloads can securely communicate with other Linode resources and even external cloud environments like AWS — without traversing the public internet.

### 🔍 **Problem Statement**

By default, LKE clusters cannot be launched inside VPCs or VLANs on Linode. This meant that any internal communication between LKE pods and other Linode resources had to go over the public internet, which:

* Exposes applications to public attack surfaces.
* Increases latency and data transfer costs.
* Complicates compliance with data privacy standards.

### 🚀 **Solution Highlights**

* **Private Networking:** LKE nodes are connected to a private VLAN for internal communication.
* **Seamless Database Access:** Direct access to Linode-hosted databases without public exposure.
* **Site-to-Site VPN:** Extends private networking to AWS or other data centers securely.
* **Automated IP Management:** Dynamic IP allocation for VLAN-attached interfaces.
* **Failover and Health Checks:** Resilient to network failures, with automatic recovery.

---

## 📌 **Deployment Steps**

1️⃣ **Clone the Repository**

```bash
git clone https://github.com/yourusername/linode-lke-vlan-manager.git
cd linode-lke-vlan-manager
```

2️⃣ **Make the Orchestration Script Executable**

```bash
chmod +x orchestration.sh
```

3️⃣ **Run the Orchestration Script**

```bash
./orchestration.sh
```

4️⃣ **Monitor the Logs**

```bash
kubectl logs -f daemonset/vlan-manager -n kube-system
```

---

## 🖥️ **Validation Steps**

1. **Check Pod Communication:**

   ```bash
   kubectl exec -it <pod-name> -- ping <private-ip>
   ```

2. **Check VPN Connectivity:**

   ```bash
   ping <aws-private-ip>
   ```

3. **Monitor VPN Status:**

   ```bash
   sudo ipsec status
   ```

4. **Monitor DaemonSet Logs:**
   The orchestration script will output the following commands:

   ```bash
   kubectl logs -f pod/vlan-manager-xxxxx -n kube-system
   kubectl logs -f pod/vlan-manager-yyyyy -n kube-system
   ```

---

## 🔄 **Troubleshooting**

* If the orchestration script fails, it automatically cleans up all resources, allowing you to re-run without conflicts.
* Check logs in the namespace:

  ```bash
  kubectl logs -n kube-system -l app=vlan-manager
  ```
* Check for VPN tunnel status:

  ```bash
  sudo ipsec status
  ```

---

## 🤝 **Contributing**

Feel free to open issues and submit PRs for improvements or bug fixes.

---

## 📄 **License**

MIT License
