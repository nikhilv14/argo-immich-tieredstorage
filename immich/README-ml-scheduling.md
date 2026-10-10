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
>   - Longhorn prerequisites: installed `open-iscsi` and `nfs-common`, and
>     labeled the node `longhorn-system=true` (the manager DaemonSet only
>     runs on labeled nodes; z690 joined 29h after the label was set on the
>     others). Without `nfs-common`, Longhorn's RWX (NFS) mounts fail on
>     Debian 13 with "fsconfig() failed: NFS: mount program didn't pass
>     remote address" because util-linux 2.41 falls back to the in-kernel
>     fsconfig path when `/sbin/mount.nfs` is missing.
>   - The LXC only bind-mounts the host render node as renderD128, so card0
>     was missing while present in sysfs; created the device node
>     (`mknod /dev/dri/card0 c 226 0`) and purged the stale udev entry
>     (`/run/udev/data/c226:0`) that kept re-creating a dangling
>     `/dev/dri/by-path/pci-0000:00:02.0-card` symlink, which broke
>     container spec generation.
>   - **Boot durability**: devtmpfs and /run are ephemeral, so the above fix
>     does not survive a container restart. A persistent oneshot unit
>     `fix-dri-dev.service` (`/usr/local/sbin/fix-dri-dev.sh`) re-creates
>     card0 and prunes dangling by-path symlinks at boot, before k3s-agent.
>     Verified by simulating the failure (rm card0 + recreate dangling
>     symlink) and re-running the script, then confirming a freshly
>     scheduled ML pod performs OpenVINO GPU inference on z690.
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
  Note on memory: resident model memory spikes well above the 512Mi request
  while models are loaded, which keeps the fleet scaled up during and shortly
  after active use. Immich ML unloads models after an idle timeout, memory
  drops back below target, and the fleet scales down to minReplicas
  (observed live: 1 → 3 on load, 3 → 1 after idle).
- Validated live 2026-10-10: **IMPORTANT CORRECTION** — deeper testing with
  `intel_gpu_top` showed 0% GPU engine utilization during 118 sustained
  predictions, and Level Zero `zeInit` fails inside every pod. Despite the
  OpenVINOExecutionProvider being listed, inference has been silently running
  on CPU. The GPU was never proven working in-pod; the provider listing alone
  is not evidence of GPU execution.
- Scale up: aggressive (up to 100% / +1 pod per 15s, no stabilization) to fill
  all three GPU slots quickly during smart-search / face-detection bursts.
- Scale down: conservative (1 pod per 60s after 300s stabilization) since GPU
  model loading is expensive and flapping wastes inference time.

## Known issue: GPU in-pod init fails (inference runs on CPU)

Deeper testing on 2026-10-10 found Level Zero `zeInit` fails inside every ML
pod, so OpenVINO silently falls back to CPU. Per-node status:

- `k3s-node1`: host Level Zero stack is an inconsistent mix (loader requires
  GLIBCXX_3.4.32 that the host libstdc++ lacks); in-pod `zeInit` ->
  `0x78000002` (device lost).
- `k3s-server-nuc`: the host has TWO GPUs (Virtio + passed-through Intel);
  the device plugin hands out correct Intel nodes, but host-side `zeInit`
  HANGS (>2 min), and `dmesg` shows missing DMC firmware
  (`i915/kbl_dmc_ver1_04.bin` ENOENT).
- `k3s-worker-z690`: in-pod `zeInit` -> `0x78000001`.

## RESOLVED (2026-10-10 evening): GPU inference works on all 3 tier=1 nodes

The three failures had THREE different root causes, one per node. All fixed
and validated with `intel_gpu_top` RCS busy% during sustained in-pod
predictions:

| Node              | Root cause                                                                                                         | Fix                                                                                    | Proof                              |
|-------------------|--------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------|------------------------------------|
| k3s-server-nuc    | (a) missing DMC firmware; (b) **Virtio GPU KMS deadlock**: virtio-gpu fbdev worker spins forever in                 | (a) `firmware-misc-nonfree` (was pending reboot); (b) blacklist `virtio_gpu`            | RCS 88-90% busy, ~1.1 GHz          |
|                   | `virtio_gpu_queue_fenced_ctrl_buffer` (fence never completes — hypervisor), holding the DRM modeset                 | (`/etc/modprobe.d/blacklist-virtio-gpu.conf`: `blacklist` + `install ... /bin/false`),  |                                    |
|                   | lock; every DRM open (incl. Level Zero loader enumerating card0) blocks -> host zeInit HUNG and the                 | then reboot. Intel iGPU is now the only DRM device (card0/renderD128).                  |                                    |
|                   | console froze mid-boot ("snd_hda_intel ... no codec found!" is the last visible line — cosmetic).                   | NOTE: Proxmox console shows a frozen last frame after SeaBIOS/GRUB — expected.         |                                    |
| k3s-node1         | Rogue hand-installed binaries layered on the jammy-repo stack: `libze_loader.so.1.20.6` (needs GLIBCXX_3.4.32,      | Deleted rogue loader, restored package symlink -> `1.11.0`; moved rogue driver         | RCS 66-86% busy, ~1.2 GHz          |
|                   | absent on jammy) retargeted onto `libze_loader.so.1`, plus noble-era driver `libze_intel_gpu.so.1.17.39758`         | to `/root/rogue-libze_intel_gpu.so.1.17.39758.bak`. `ldconfig` kept re-flipping the     |                                    |
|                   | symlinked as the driver (needs igc/gmmlib versions jammy does not have). ldconfig prefers the highest               | driver symlink, so the rogue .so had to leave the library path entirely. Jammy set:     |                                    |
|                   | SONAME version -> must remove the rogue file, not just relink.                                                      | `intel-level-zero-gpu 1.3.26241.33-647~22.04`, `level-zero 1.11.0`, `libigc1 1.0.13822` |                                    |
| k3s-worker-z690   | Host/LXC Level Zero was already fine; in-pod `0x78000001` traced to **device-node permissions**: the Intel          | Manifest fix (machine-learning.yaml): `supplementalGroups: [109, 44, 992]` —           | RCS 56% busy, ~810 MHz             |
|                   | device plugin injects `/dev/dri/by-path/*` as device nodes with **host ownership** (root:render), and Debian's      | 109 = render GID on Ubuntu (node1), 992 = render GID on Debian (nuc, z690).            |                                    |
|                   | render GID is 992, not 109. NEO (compute-runtime) enumerates through by-path; open() -> EACCES -> DEVICE_LOST.       |                                                                                        |                                    |

Diagnostic method that found the z690 in-pod failure: ephemeral debug
container (`kubectl debug --target=<ml-container>`) sharing the pod PID
namespace, strace attached to a sleeping zeInit python process — the
`openat("/dev/dri/by-path/...-render") = -1 EACCES` was unambiguous. A
pod-internal strace requires attaching as the pod user (1000); root cannot
attach inside the container's userns view.

Host-side validation (all nodes): `python3 ctypes` zeInit + zeDriverGet
against `libze_loader.so.1` returns `0x0` with >=1 driver; on the host also
retest as uid 1000 with the node's REAL render GID (`setpriv --reuid 1000
--regid 1000 --groups <render-gid>`) because root passes even when the
unprivileged path is broken.

In-pod validation (all nodes): zeInit `0x0` + `drivers=1`; 135/135
concurrent `/predict` calls (clip visual ViT-B-32__openai + buffalo_l
facial detection/recognition) across the 3 replicas; per-node
`intel_gpu_top`: z690 RCS 56.12%, nuc RCS 89.9%, node1 RCS 86.2% busy.
HPA held 3/3 during load (memory 104%/80%), matching documented scale
behavior.

ML API note (v3.3.1): `/predict` takes multipart `image` file +
`entries` form field = JSON of PipelineRequest: e.g.
`{"clip":{"visual":{"modelName":"ViT-B-32__openai"}},"facial-recognition":{"detection":{"modelName":"buffalo_l"},"recognition":{"modelName":"buffalo_l"}}}`.
The request config is STRICT (extra=forbid) — do not pass option keys like
`minScore` inside task slots; omit options entirely and defaults apply.
