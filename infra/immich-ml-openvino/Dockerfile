# immich-machine-learning with an OpenVINO execution provider.
#
# v3.4.2 shipped no -openvino build upstream (checked against the GHCR tag
# listing: v3.4.2-openvino -> 404, v3.4.1-openvino -> 200), so the deployment
# pinned the CPU image and ML silently ran on CPU despite
# ACCELERATORS=openvino / MACHINE_LEARNING_DEVICE=GPU.
#
# Fix without changing the Immich version: derive from the exact CPU image,
# swap the plain onnxruntime for Intel's onnxruntime-openvino wheel (the
# wheel bundles the OpenVINO runtime beside the EP, which is what upstream's
# own build does), and add the OpenCL ICD loader that NEO enumerates through.
# Level Zero + gmmlib are NOT installed here: the pod mounts the host's
# per-node copies (see machine-learning.yaml) so driver and gmmlib versions
# match, which is required for zeInit to succeed.
#
# Build (any docker host):
#   docker build -t immich-machine-learning:v3.4.2-openvino .
#
# There is no registry in this cluster, so import into containerd on each
# immich.ml/tier=1 node (k3s-node1, k3s-server-nuc):
#   docker save immich-machine-learning:v3.4.2-openvino | gzip -1 > ml-openvino.tar.gz
#   # copy to the node, then:
#   gunzip -c ml-openvino.tar.gz > /tmp/ml-openvino.tar
#   sudo k3s ctr --namespace k8s.io images import /tmp/ml-openvino.tar
#
# Then bump `image:` in immich/machine-learning.yaml and let ArgoCD roll it.
FROM ghcr.io/immich-app/immich-machine-learning:v3.4.2

ARG ORT_OPENVINO_VERSION=1.24.1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      ocl-icd-libopencl1 \
 && curl -fsSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py \
 && /opt/venv/bin/python /tmp/get-pip.py \
 && /opt/venv/bin/python -m pip uninstall -y onnxruntime \
 && /opt/venv/bin/python -m pip install --no-cache-dir --no-deps \
      "onnxruntime-openvino==${ORT_OPENVINO_VERSION}" \
 && rm -f /tmp/get-pip.py \
 && rm -rf /var/lib/apt/lists/*

# Fail fast at build time if the EP did not materialise.
RUN /opt/venv/bin/python -c \
      "import onnxruntime as o; p=o.get_available_providers(); \
       assert 'OpenVINOExecutionProvider' in p, p; print('ORT', o.__version__, p)"
