# immich-machine-learning OpenVINO image

`immich-machine-learning:v3.4.2-openvino` — the upstream v3.4.2 CPU image plus an
OpenVINO-enabled ONNX Runtime. Needed because Immich never published a
`-openvino` build for v3.4.2 (`v3.4.2-openvino` → 404 on GHCR), so the stack was
running face/CLIP inference on CPU despite `ACCELERATORS=openvino` and
`MACHINE_LEARNING_DEVICE=GPU`.

## What it adds

- `onnxruntime-openvino==1.24.1` (replaces plain `onnxruntime`), which bundles the
  OpenVINO runtime beside the execution provider — the same bundling upstream's own
  OpenVINO build does.
- `ocl-icd-libopencl1`, the OpenCL ICD loader NEO enumerates through.
- Nothing else: Level Zero (`libze_loader.so.1`, `libze_intel_gpu.so.1`) and the
  host-matched `libigdgmm.so.12` are bind-mounted per node from
  `machine-learning.yaml`. Do not install those in the image — a mismatched gmmlib
  silently breaks `zeInit` and OpenVINO falls back to CPU.

Verified at build time: `get_available_providers()` contains
`OpenVINOExecutionProvider`.

## Where it runs

Only on `immich.ml/tier=1` nodes — `k3s-node1` (UHD770) and `k3s-server-nuc`
(UHD630 via i915). The pod requests `gpu.intel.com/i915: 1`; hp-g9 has no iGPU and
z690 cannot attach the volumes.

## Maintenance

Bump `ORT_OPENVINO_VERSION` alongside the upstream Immich version, rebuild, and
re-import into containerd on **both** tier=1 nodes before ArgoCD rolls the
deployment — otherwise the new pod lands on the node that lacks the image and
fails with ImagePullBackOff (intentional: it must not silently fall back to CPU):

```
docker build -t immich-machine-learning:<ver>-openvino .
docker save immich-machine-learning:<ver>-openvino | gzip -1 > ml-openvino.tar.gz
# on each tier=1 node:
gunzip -c ml-openvino.tar.gz > /tmp/ml-openvino.tar
sudo k3s ctr --namespace k8s.io images import /tmp/ml-openvino.tar
```

Confirm after rollout: the pod log reports `Loaded execution provider: OpenVINO`,
and `onnxruntime.get_available_providers()` inside the pod lists
`OpenVINOExecutionProvider`.
