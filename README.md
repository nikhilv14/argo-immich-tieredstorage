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
| `k3s-worker-z690` | privileged LXC (Debian 13) | UHD770 iGPU; **cannot attach Longhorn volumes** — kernel iSCSI netlink is init_net-only, iscsid in the LXC netns gets ECONNREFUSED (root-caused 2026-10-11, see DB README); DB+redis hard-exclude it |
| `k3s-server-hp-g9`| VM                      | CPU only (immich.ml/tier=2); holds the 2nd Longhorn replica of the DB volume |

Storage: Longhorn (`ssd-cache` SC, 2 replicas) for hot data; `truenas-nfs`
(democratic-csi) for the library (`immich-library-nfs`, 2Ti), upload, cache,
profile and sync-queue; `nas-rwx` (nfs.csi) only for the WAL archive.

`immich-server` transcodes on the iGPU: it runs the VAAPI-enabled image from
`infra/immich-vaapi/` and is pinned to the two `immich.ml/tier=1` nodes
(`k3s-node1` UHD770, `k3s-server-nuc` UHD660). Without the extra
`intel-media-va-driver-non-free` layer the upstream image has no libva at all
and every transcode falls back to software.

The library moved off `nas-rwx` on 2026-11-18: that class mounts
`soft,timeo=30`, which fails a write after ~3s instead of retrying and left 10
originals truncated in the 2026-01-21 import. `truenas-nfs` mounts
`hard,timeo=600,nconnect=8` and gives the library its own TrueNAS dataset
(`k8s-nfs/vols/pvc-*`) and snapshot target. The old `immich-library` PVC is
retained, unreferenced, as a rollback until the copy is confirmed good.

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

## Upgrading Immich

The version is pinned in exactly two places, and both must move together:

| File | Image |
|------|-------|
| `immich/server-deployment.yaml` | `ghcr.io/immich-app/immich-server:<tag>` |
| `immich/machine-learning.yaml` | `ghcr.io/immich-app/immich-machine-learning:<tag>-openvino` |

Before bumping: read the release notes for breaking changes, confirm the tagged
manifests exist on ghcr, and check the nightly Immich database backup is fresh
(`time() - immich_database_backup_last_timestamp_seconds`). No database image
change is needed for a patch/minor bump - `database/statefulset.yaml` runs
`ghcr.io/immich-app/postgres:15-vectorchord0.5.3`, which is newer than the
`14-vectorchord0.4.3` upstream pins in its own docker-compose, and Immich runs
its schema migrations on server startup.

Server rolls with `maxSurge: 1, maxUnavailable: 0`, so the upgrade is
zero-downtime. Validate afterwards: `immich_server_info` shows the new version,
`/api/server/ping` answers, and `immich_exporter_up` stays 1.
