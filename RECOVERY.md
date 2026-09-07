# VLAN Config Controller – Recovery

**This document has moved to [docs/DAY2-OPERATIONS.md#recovering-a-stuck-vlan-config-controller](docs/DAY2-OPERATIONS.md#recovering-a-stuck-vlan-config-controller).**

It covers why the controller gets stuck (leader lock, reboot lock, pod-on-rebooting-node, CrashLoopBackOff), how the leader lock and auto-recovery work normally, and the full numbered recovery procedures: unsticking the leader lock, fixing DaemonSet-to-etcd connectivity, unsticking the reboot lock, recovering from all-nodes-shut-down, and the etcd key quick reference.
