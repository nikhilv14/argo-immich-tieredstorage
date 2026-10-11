# Immich on k3s — tiered storage & GPU ML

ArgoCD-managed manifests for a homelab Immich deployment on k3s, with:

- **Immich server** (2 replicas) + **Postgres** (StatefulSet, single instance
  on a Longhorn-replicated volume with WAL archiving + nightly volume backups)
- **ML workers** with tiered GPU scheduling: one pod per Intel iGPU node
  (tier=1), CPU-only node (tier=2) as last resort, HPA min 1 / max 3
- **Redis**, ingress, storage PVCs, Prometheus metrics

## Repo layout / ArgoCD apps

| Path         | ArgoCD app       | Contents                                                        |
|--------------|------------------|-----------------------------------------------------------------|
| `immich/`    | `immich-app`     | server, ML deployment + HPA, config, ingress, node labels       |
| `database/`  | `immich-database`| postgres StatefulSet, redis, config, secrets                    |
| `storage/`   | `immich-storage` | PVCs (library, upload, cache, DB volumes)                       |
| `monitoring/`| `immich-monitoring` | ServiceMonitor, Grafana dashboard, recording/alert rules      |

`root` is an app-of-apps that manages all of the above (including the child
Applications themselves). All apps: auto-sync + prune + selfHeal.

Deep-dive docs:
- `immich/README-ml-scheduling.md` — ML tiered scheduling, the GPU debugging
  saga (all 3 tier=1 nodes now do real iGPU inference), validation methods
- `database/README-db-affinity.md` — DB/redis node affinity, PV nodeAffinity
  removal procedure, Longhorn-on-z690 limitation, ArgoCD gotchas

## Cluster

| Node              | Type                    | Role in the stack                          |
|-------------------|-------------------------|--------------------------------------------|
| `k3s-node1`       | VM (Ubuntu 22.04)       | runs almost everything: argocd, monitoring, DB, redis, ingress, Longhorn core; UHD770 iGPU |
| `k3s-server-nuc`  | VM (Debian 13)          | UHD660 iGPU (passed through); console is **serial only** (ttyS0, Display:none) |
| `k3s-worker-z690` | privileged LXC (Debian 13) | UHD770 iGPU; **cannot attach Longhorn volumes** (CSI attach fails — see DB README) |
| `k3s-server-hp-g9`| VM                      | CPU only (immich.ml/tier=2); holds the 2nd Longhorn replica of the DB volume |

Storage: Longhorn (`ssd-cache` SC, 2 replicas) for hot data; `nas-rwx`
(NFS CSI) for the 2Ti library and WAL archive.

## Operational rules

- **Do not restart `immich-server`** or trigger `storageTemplateMigration`
  without need. ML pod churn is fine.
- Commit as `Nikhil <nikhil@dev-env.lan>`; push needs
  `SSH_AUTH_SOCK=~/.ssh-agent.socket`. ArgoCD auto-syncs from `main`.
- `kubectl` works locally (`KUBECONFIG=~/.kube/config`). Nodes: `ssh
  nikhil@<node>` with the same SSH_AUTH_SOCK, passwordless sudo.
- **ArgoCD `root` is an app-of-apps with selfHeal**: it re-applies child
  Application objects, silently re-enabling their auto-sync. Manual surgery
  (scale-downs, PV swaps) requires disabling selfHeal on `root` FIRST, then
  the child apps; re-enable afterwards.
- A failing ArgoCD sync retries forever (~3 min apart) and re-applies ALL
  resources in the app each attempt.
- PV `spec.nodeAffinity` is **immutable** here — removing a pin requires the
  PV/PVC recreate procedure in `database/README-db-affinity.md` (Retain first;
  watch for StatefulSet volumeClaimTemplates auto-creating a PVC that binds to
  a fresh empty volume).
- DB and redis volumes are `Retain`-policy PVs, name-bound via claimRef.
- `kbl_dmc`/GPU debugging recipe, zeInit ctypes test, and the
  `intel_gpu_top` RCS-busy% acceptance proof are in the ML README.
