# AGENTS.md — operational guide for agents working in this repo

This repo is ArgoCD-managed infrastructure for a live homelab Immich stack.
Read this plus the deep-dive docs before changing anything:

- `immich/README-ml-scheduling.md` — ML GPU scheduling; the full GPU debugging
  record; validation methods (zeInit ctypes test, intel_gpu_top RCS busy%)
- `database/README-db-affinity.md` — DB/redis affinity, PV swap procedure,
  Longhorn-on-z690 limitation, ArgoCD gotchas
- `README.md` — repo/cluster overview

## Environment

- `kubectl` works locally (`KUBECONFIG=~/.kube/config`).
- SSH to nodes: `SSH_AUTH_SOCK=~/.ssh-agent.socket`, user `nikhil`,
  passwordless sudo. Nodes: `k3s-node1`, `k3s-server-nuc`,
  `k3s-worker-z690`, `k3s-server-hp-g9`.
- Git push needs the same SSH_AUTH_SOCK. Commit as
  `Nikhil <nikhil@dev-env.lan>` (use `git -c user.name=Nikhil -c
  user.email=nikhil@dev-env.lan`).
- ArgoCD auto-syncs every app from `main`. Pushing = deploying. To speed up a
  sync: `kubectl -n argocd annotate application/<app>
  argocd.argoproj.io/refresh=normal --overwrite`.

## Critical rules

1. **Do not restart `immich-server`** or trigger `storageTemplateMigration`
   without explicit need. ML pod churn is fine.
2. **`root` is an app-of-apps with selfHeal.** It re-applies child Application
   objects, silently re-enabling their `syncPolicy.automated`. For manual
   surgery (scale to 0, PV swaps): disable selfHeal on `root` first, then on
   `immich-database`/`immich-storage`/`immich-app`, re-enable when done.
3. **A failing ArgoCD sync retries forever** (~3 min) and re-applies every
   resource in the app each attempt — it will undo your manual changes (e.g.
   replica counts). Fix the drift in git, not just in the cluster.
4. **PV `spec.nodeAffinity` is immutable on this cluster.** To remove a pin:
   follow the procedure in `database/README-db-affinity.md` exactly — Retain
   policy first, then PVC delete → PV delete → PV recreate (claimRef, no
   uid) → PVC recreate. Watch for StatefulSet `volumeClaimTemplates`
   auto-recreating a deleted PVC that then binds to a fresh EMPTY volume
   (scale the STS to 0 first).
5. **`k3s-worker-z690` cannot attach Longhorn volumes** (CSI
   DeadlineExceeded, LXC limitation). Do not schedule stateful workloads
   there; redis already hard-excludes it.
6. DB and redis PVs are `Retain`-policy and name-bound via claimRef. Do not
   delete the Longhorn volumes.
7. The DB pod/redis are pinned to node1 only by SOFT preference — on a node1
   outage they may/should fail over (validated). Do not "fix" them back to
   hard pins.

## Known live-state quirks (cluster state, not in git)

- `k3s-server-nuc`: `virtio_gpu` blacklisted (`/etc/modprobe.d/blacklist-virtio-gpu.conf`),
  display device removed, console over serial (ttyS0). Re-validate GPU after
  any hardware change: host zeInit, in-pod zeInit, `intel_gpu_top` RCS busy%.
- `k3s-node1` runs the jammy-repo Level Zero stack
  (`intel-level-zero-gpu 1.3.26241.33`, `level-zero 1.11.0`) — do not "upgrade"
  it to noble versions (GLIBCXX_3.4.32 unavailable on jammy).
- ML `/predict` API (v3.3.1): multipart `image` + `entries` JSON
  (PipelineRequest, STRICT — no option keys inside task slots; see ML README).

## Validation checklist after GPU/storage changes

1. Host-side: `python3 /tmp/zeitest.py` (ctypes zeInit + zeDriverGet; expect
   `0x0` and `drivers=1`), also as uid 1000 with the node's real render GID
   (Debian render GID = 992, Ubuntu = 109).
2. In-pod: `kubectl -n immich exec -i <ml-pod> -- python3 - < zeitest.py`.
3. Real proof: sustained `/predict` load while `intel_gpu_top -s 2000 -o
   file.csv` runs on the node — require nonzero **RCS busy%**.
4. After DB/redis work: `pg_isready -U immich -d immich`,
   `select count(*) from asset` (7102 assets at last check), `redis-cli ping`,
   and confirm ArgoCD apps Synced/Healthy.
