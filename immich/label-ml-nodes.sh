#!/usr/bin/env bash
# Tag k3s nodes for tiered Immich ML scheduling (see machine-learning.yaml).
#
#   tier=1 : GPU nodes  -> preferred for all ML replicas
#   tier=2 : CPU node   -> k3s-server-hp-g9, last priority, never an HPA target
#
# Note: gpu.intel.com/i915 extended resources still gate actual placement, so
# pods only ever land on tier=1 nodes regardless of tier=2 eligibility.
set -euo pipefail

# --- Tier 1: GPU nodes (one iGPU each) -------------------------------------
kubectl label node k3s-node1 \
  immich.ml/tier=1 immich.ml/gpu-model=uhd770 --overwrite

kubectl label node k3s-server-nuc \
  immich.ml/tier=1 immich.ml/gpu-model=uhd660 --overwrite

kubectl label node k3s-worker-z690 \
  immich.ml/tier=1 immich.ml/gpu-model=uhd770 --overwrite

# --- Tier 2: CPU-only fallback, last priority -------------------------------
kubectl label node k3s-server-hp-g9 \
  immich.ml/tier=2 immich.ml/gpu-model=none --overwrite

echo "--- Result ---"
kubectl get nodes -L immich.ml/tier -L immich.ml/gpu-model
