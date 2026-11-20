# immich-server with VAAPI/QSV support.
#
# The upstream image ships no libva at all, so immich-server's transcoder can
# never initialise QSV: every job logs "No VA display found for device
# /dev/dri/renderD128" and falls back to software encoding. trixie carries the
# iHD driver in non-free, so it is a one-layer addition.
#
# Build (any docker host, ~2 min):
#   docker build -t immich-server:v3.4.2-vaapi .
#
# There is no registry in this cluster, so the image is imported into
# containerd on each node that can run immich-server (the immich.ml/tier=1
# nodes, i.e. k3s-node1 and k3s-server-nuc):
#   docker save immich-server:v3.4.2-vaapi | gzip -1 > immich-vaapi.tar.gz
#   # copy to the node, then:
#   gunzip -c immich-vaapi.tar.gz > /tmp/immich-vaapi.tar
#   sudo k3s ctr --namespace k8s.io images import /tmp/immich-vaapi.tar
#
# Bump the tag alongside the upstream version in immich/server-deployment.yaml.
FROM ghcr.io/immich-app/immich-server:v3.4.2

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libva2 \
      libva-drm2 \
      libva-glx2 \
      intel-media-va-driver-non-free \
 && rm -rf /var/lib/apt/lists/*
