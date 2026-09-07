# Deprecated — see docs/DEPLOYMENT.md and docs/DAY2-OPERATIONS.md

This document described an earlier design using a `dedicated-migration=true:NoSchedule` taint/label and a different `post-migration-consolidate.sh` behavior (deleting and waiting on individual pods rather than re-applying manifests with switched affinity). That design has been superseded and this file is kept only so old links don't 404 — its content no longer matches the actual code in this repo.

The current, accurate documentation for everything this file used to cover:

- **Creating and tainting the infra pool** (now `infra-pool`, not `dedicated-migration`): [docs/DEPLOYMENT.md § Installation](docs/DEPLOYMENT.md#installation), step 1.
- **Why a dedicated pool exists at all, and what runs on it** (etcd, `vlan-config-controller`, CoreDNS, and now Kyverno): [docs/DEPLOYMENT.md § Why a dedicated infra-pool node pool](docs/DEPLOYMENT.md#why-a-dedicated-infra-pool-node-pool) and the Architecture components table above it.
- **The `vlan-not-ready` app-pool taint** (now permanent, paired with a Kyverno-injected `nodeSelector` — a materially different mechanism than what this file described): [docs/DAY2-OPERATIONS.md § Applying the vlan-not-ready taint](docs/DAY2-OPERATIONS.md#applying-the-vlan-not-ready-taint).
- **Migrating off `infra-pool` and deleting it** (running `post-migration-consolidate.sh`, what it actually does today, and the manual pool-deletion sequence): [docs/DEPLOYMENT.md § Migration: Retiring infra-pool](docs/DEPLOYMENT.md#migration-retiring-infra-pool).

If you're looking at this file because an old bookmark or script comment pointed here, update that reference to one of the links above.
