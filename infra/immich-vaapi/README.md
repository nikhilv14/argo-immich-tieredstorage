# immich-server VAAPI image

`immich-server:v3.4.1-vaapi` — upstream v3.4.1 plus `libva2`, `libva-drm2`,
`libva-glx2` and `intel-media-va-driver-non-free` (iHD). See the Dockerfile for
the build and the per-node `k3s ctr images import` steps.

## Why

The upstream image has no VAAPI userspace at all (`ldconfig -p | grep libva` is
empty, `/usr/lib/x86_64-linux-gnu/dri` does not exist), and that is true of
v3.3.1 and v3.4.1 alike. So transcoding always fell back to software, logging a
burst of `Device creation failed: -22` / `No VA display found` per job. Both
versions behave identically, so this was never caused by an Immich upgrade.

With the driver present, `ffmpeg -init_hw_device qsv=hw,child_device=/dev/dri/renderD128`
initialises and `h264_qsv` encodes in hardware.

## Where it runs

`immich-server` is pinned with a required node affinity to `immich.ml/tier=1` —
`k3s-node1` (UHD770) and `k3s-server-nuc` (UHD660 passed through the VM). Both
nodes mount `/dev/dri` from the host. `k3s-server-hp-g9` is CPU-only and
`k3s-worker-z690` cannot attach the volumes, so neither runs the server.

`LIBVA_DRIVER_NAME=iHD` and `LIBVA_DRIVERS_PATH=/usr/lib/x86_64-linux-gnu/dri`
are set on the container.

## Maintenance

When Immich is upgraded, change the `FROM` tag, rebuild, re-import on both
tier=1 nodes, then bump `image:` in `immich/server-deployment.yaml` and let
ArgoCD roll it. Until the new image is imported, the pods will fail with
ImagePullBackOff rather than silently falling back — that is intentional.
