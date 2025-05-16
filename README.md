# Linode LKE VLAN Orchestration

This repository contains a fully automated orchestration script and Kubernetes YAML manifests for deploying a VLAN-backed LKE cluster on Linode. This setup includes private VLAN communication for LKE nodes and integration with a Linode VPC.

## 📌 **Features:**

- Fully automated deployment with `00-Orchestration-Script.sh`
- Private VLAN communication for secure node-to-node communication
- Site-to-Site VPN support for private IP communication with external data centers
- Kubernetes-native DaemonSets and Deployments for automated VLAN attachment
- Seamless IP allocation and release through REST API
- Health checks and auto-healing mechanisms

---

## 🚀 **Deployment Steps:**

1️⃣ **Clone the Repository:**

```bash
 git clone <your-repo-url>
 cd Linode-LKE-VLAN-Orchestration
```

2️⃣ **Set Kubernetes Context:**

```bash
kubectl config current-context
```

3️⃣ **Make the Orchestration Script Executable:**

```bash
chmod +x 00-Orchestration-Script.sh
```

4️⃣ **Run the Orchestration Script:**

```bash
./00-Orchestration-Script.sh
```

---

## 🔎 **Validation:**

To verify the deployment:

```bash
kubectl get pods -n kube-system
kubectl get daemonset vlan-manager -n kube-system
kubectl get deployment vlan-leader-manager -n kube-system
```

Check IP allocations:

```bash
kubectl exec -n kube-system <leader-pod-name> -- cat /mnt/vlan-ip/vlan-ip-list.txt
```

Validate routes:

```bash
ip route show | grep <DEST_SUBNET>
```

---

## 🛠️ **Cleanup:**

To completely remove the deployment:

```bash
./00-Orchestration-Script.sh --cleanup
```

---

## ⚠️ **Known Issues:**

- Ensure `linode-cli` is properly configured with API tokens.
- PVC must be released before re-deployment.
- If the initializer job gets stuck, ensure proper permissions on the PVC.

---

## 🤝 **Contributing:**

Feel free to open issues and submit PRs to enhance the automation and deployment experience.

---

## 📄 **License:**

MIT License. See `LICENSE` for more information.

---

## 📧 **Support:**

For any issues, please contact [your-email@example.com].

