# Immich ML: tiered GPU scheduling

> **Cluster reality (validated 2026-10-10 against the live cluster)**
>
> - `k3s-node1` (Intel 46d1, Alder Lake-S UHD770): `gpu.intel.com/i915=1` OK.
> - `k3s-worker-z690` (i915, **privileged LXC**, previously unprivileged):
>   - Device plugin socket dir was owned by uid 100000 → chowned to root.
>   - The privileged conversion left ~22k rootfs files owned by the old
>     mapped uid 100000 (including setuid `/bin/mount`), which made every
>     kubelet mount fail with "must be superuser"; fixed with a
>     `find / -xdev -uid 100000 -exec chown root:root {} +` pass.
>   - Level Zero libs were missing (Debian repos don't ship them): installed
>     `intel-level-zero-gpu` + `libze1` from Intel's apt repo
>     (`repositories.intel.com/gpu/ubuntu noble`) on z690 and nuc.
>   - Longhorn prerequisites: installed `open-iscsi` and labeled the node
>     `longhorn-system=true` (the manager DaemonSet only runs on labeled
>     nodes; z690 joined 29h after the label was set on the others).
>   - The LXC only bind-mounts the host render node as renderD128, so card0
>     was missing while present in sysfs; created the device node
>     (`mknod /dev/dri/card0 c 226 0`) and purged the stale udev entry
>     (`/run/udev/data/c226:0`) that kept re-creating a dangling
>     `/dev/dri/by-path/pci-0000:00:02.0-card` symlink, which broke
>     container spec generation.
>   - The ML pod skips the projected service-account token (a projected
>     tmpfs mount failed while the chown pass was still missing).
>   - The `/dev/dri` hostPath was dropped in favor of device-plugin node
>     injection (a whole-dir bind mount collided with the injected
>     by-path device).
> - `k3s-server-nuc`: initially exposed only a Red Hat Virtio GPU (DRIVER=virtio-pci)
>   and advertised no i915. After a VM reboot on 2026-10-10 the Intel iGPU
>   (UHD660) became visible and the node now advertises
>   `gpu.intel.com/i915=1`. All 3 tier=1 nodes now have one GPU slot each.
>   Caveat: the plugin pod on nuc shows periodic restarts; if i915 capacity
>   drops again after a reboot, re-check `/dev/dri` and the plugin pod logs.
> - `k3s-server-hp-g9`: a virtio VM; carries the stale
>   `intel.feature.node.kubernetes.io/gpu=true` label despite having no usable
>   GPU. Harmless (no i915 capacity), but the label is misleading.
>
> HPA maxReplicas is 3, matching the 3 tier=1 nodes x 1 iGPU each. The
> full fleet of 3 GPU-backed ML replicas is reachable as of 2026-10-10.

## Node tags (applied live on 2026-10-10; script kept for re-apply)

| Node                | `immich.ml/tier` | `immich.ml/gpu-model` | Notes                          |
|---------------------|------------------|-----------------------|--------------------------------|
| k3s-node1           | 1                | uhd770                | iGPU, OpenVINO via Level Zero  |
| k3s-server-nuc      | 1                | uhd660                | iGPU, OpenVINO via Level Zero  |
| k3s-worker-z690     | 1                | uhd770                | iGPU, OpenVINO via Level Zero  |
| k3s-server-hp-g9    | 2                | none                  | CPU only, LAST priority        |

`immich.ml/tier` is the scheduling tag used by the deployment affinity.
`immich.ml/gpu-model` is informational, for `kubectl get nodes -L` visibility
and future model-aware scheduling.

## Scheduling rules (machine-learning.yaml)

1. **Hard requirement**: node must carry `immich.ml/tier` in {1, 2}, OR (grace
   window before tagging is applied) the Intel device plugin GPU feature label
   `intel.feature.node.kubernetes.io/gpu=true`.
2. **Soft preference**: `tier=1` nodes are weighted 100 vs 10 for `tier=2`, so
   CPU (`k3s-server-hp-g9`) is only ever picked when no GPU node is feasible.
3. **Spread**: soft pod anti-affinity on `kubernetes.io/hostname` plus the
   topology spread constraint keep replicas on distinct nodes. The
   `gpu.intel.com/i915: 1` limit (1 iGPU per node) enforces this hard anyway.
4. **CPU fallback caveat**: because every pod requests `gpu.intel.com/i915: 1`,
   a pod cannot actually schedule on the GPU-less hp-g9. The tier=2 affinity is
   future-proofing: to genuinely run ML there (CPU via OpenVINO), drop the
   `i915` limit and the Level Zero hostPath mounts, and set
   `MACHINE_LEARNING_DEVICE=CPU` (e.g. a dedicated CPU-only deployment or a
   kustomize overlay). Keeping the limit is recommended so GPU slots are never
   silently degraded to CPU under load.

## HPA rules (machine-learning-hpa.yaml)

- `minReplicas: 1`, `maxReplicas: 3`: ceiling = 3 tier=1 nodes x 1 iGPU each.
  Scaling past 3 can only create Pending pods.
- Metrics: CPU 75% and memory 80% utilization (max of the two triggers scale).
  **Note:** loaded models keep resident memory at ~150%+ of the 512Mi request,
  so once all three pods have served at least one request, the memory metric
  effectively keeps the fleet at 3 warm replicas instead of scaling down to a
  cold pod. That is intentional: warm pods avoid re-downloading/re-loading
  models on every burst. Node headroom is large (13-41% used). If you prefer
  scale-to-one at idle, remove the memory metric and lower the model-cache
  footprint (e.g. set `MACHINE_LEARNING_MODEL_TTL`-style cache eviction or
  raise the memory request so utilization stays below 80%).
- Validated live 2026-10-10: a single real image-embedding request scaled the
  fleet 1 -> 3 (one pod per iGPU node), each pod loaded the visual model via
  OpenVINOExecutionProvider on its own iGPU, and inference returned HTTP 200
  from node1 (UHD770), nuc (UHD660) and z690 (UHD770).
- Scale up: aggressive (up to 100% / +1 pod per 15s, no stabilization) to fill
  all three GPU slots quickly during smart-search / face-detection bursts.
- Scale down: conservative (1 pod per 60s after 300s stabilization) since GPU
  model loading is expensive and flapping wastes inference time.
