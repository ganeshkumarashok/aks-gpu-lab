#!/usr/bin/env bash
# Module 2 -- add a FULLY MANAGED GPU node pool.
#
# `--enable-managed-gpu=true` makes AKS install and maintain all four components:
#   1. NVIDIA GPU driver
#   2. NVIDIA Kubernetes device plugin  (advertises nvidia.com/gpu)
#   3. DCGM + dcgm-exporter            (GPU metrics on port 19400)
#   4. GPU health signals in NPD       (UnhealthyNvidiaDevicePlugin, etc.)
#
# Without the flag you get the driver ONLY -- that is the documented default,
# not the full stack. See docs/accuracy.md.
#
# Usage: 20-add-managed-gpu-nodepool.sh [t4|a10]

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

TIER="${1:-t4}"
case "$TIER" in
  t4)  SKU="$LAB_SKU_T4";  POOL="$LAB_NODEPOOL_T4" ;;
  a10) SKU="$LAB_SKU_A10"; POOL="$LAB_NODEPOOL_A10" ;;
  a100) SKU="$LAB_SKU_A100"; POOL="$LAB_NODEPOOL_A100" ;;
  *)   fail "Unknown tier '$TIER'. Use: t4 | a10 | a100"; exit 2 ;;
esac

step "Adding managed GPU node pool '$POOL' ($SKU)"

if az aks nodepool show --resource-group "$LAB_RG" --cluster-name "$LAB_CLUSTER" \
     --name "$POOL" >/dev/null 2>&1; then
  warn "Node pool '$POOL' already exists."
  info "gpuProfile fields (managementMode, migStrategy, driver) are IMMUTABLE after"
  info "creation. To change the install profile you must delete and recreate:"
  info "  az aks nodepool delete -g $LAB_RG --cluster-name $LAB_CLUSTER -n $POOL"
  exit 0
fi

info "This takes roughly 5-10 minutes; the driver and managed components install at"
info "node provisioning time, so first boot is slower than a CPU node pool."

# NOTE: --enable-cluster-autoscaler is deliberately absent. Managed GPU node pools
# do not support the cluster autoscaler during preview; scale with
# `az aks nodepool scale` instead. See docs/accuracy.md.
az aks nodepool add \
  --resource-group "$LAB_RG" \
  --cluster-name "$LAB_CLUSTER" \
  --name "$POOL" \
  --node-count 1 \
  --node-vm-size "$SKU" \
  --node-taints "$LAB_GPU_TAINT" \
  --enable-managed-gpu=true \
  -o none

ok "Node pool '$POOL' created"

step "Confirming the managed GPU profile was applied"
az aks nodepool show \
  --resource-group "$LAB_RG" --cluster-name "$LAB_CLUSTER" --name "$POOL" \
  --query gpuProfile -o json

info "Expect: driver=Install, nvidia.managementMode=Managed."
info "If nvidia is null, the pool was created WITHOUT the managed stack."
step "Next"
info "Run scripts/30-verify-managed-stack.sh $TIER"
