#!/usr/bin/env bash
# Module 6 (capstone) -- add the 2-node H100 pool.
#
# Standard_ND96isrf_H100_v5: 8x H100 80GB, RdmaEnabled=True, 96 vCPU.
# Two nodes is the ENTIRE standardNDSFH100v5Family quota in this subscription,
# so there is no capacity to run a second attempt in parallel.
#
# Two things here are unverified territory, unlike modules 0-5:
#   1. Whether --enable-managed-gpu=true works on ND-series at all. It is proven
#      on NC (T4, A100) and NV (A10) families only. If the RP rejects it, rerun
#      with CAP_MANAGED_GPU=false to fall back to the documented default
#      (driver-only), and note that you then own the device plugin yourself.
#   2. Whether InfiniBand is usable from pods. No AKS documentation covers
#      NVIDIA InfiniBand; see modules/06-capstone-multinode.md.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

: "${CAP_MANAGED_GPU:=true}"

step "Preflight -- SKU availability and quota in $CAP_LOCATION"

SUB_ID=$(az account show --query id -o tsv 2>/dev/null || true)
[ -n "$SUB_ID" ] || { fail "Not logged in. Run: az login"; exit 1; }

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.Compute/skus?api-version=2021-07-01&\$filter=location%20eq%20'$CAP_LOCATION'" \
  -o json > "$TMPD/skus.json" 2>/dev/null || echo '{"value":[]}' > "$TMPD/skus.json"
az vm list-usage --location "$CAP_LOCATION" -o json > "$TMPD/usage.json" 2>/dev/null || echo '[]' > "$TMPD/usage.json"

while IFS='|' read -r verdict msg; do
  [ -z "$verdict" ] && continue
  case "$verdict" in
    OK)   ok "$msg" ;;
    WARN) warn "$msg" ;;
    *)    fail "$msg"; exit 1 ;;
  esac
done <<EOF
$("$(dirname "$0")/_check_skus.py" "$TMPD/skus.json" "$TMPD/usage.json" "$CAP_SKU" "capstone / module 6")
EOF

# Quota and availability are necessary but NOT sufficient. Azure can still return
# AllocationFailed at provision time when a region has no free capacity for the
# SKU. There is no API that promises capacity in advance.
warn "Quota and availability do not guarantee capacity."
info "This SKU can still fail with AllocationFailed at provision time. If that"
info "happens it is a capacity signal, not a configuration error -- retry later"
info "or try another region where you hold quota."

step "Creating $CAP_NODE_COUNT-node H100 pool '$CAP_NODEPOOL' ($CAP_SKU)"

if az aks nodepool show -g "$CAP_RG" --cluster-name "$CAP_CLUSTER" -n "$CAP_NODEPOOL" >/dev/null 2>&1; then
  warn "Node pool '$CAP_NODEPOOL' already exists -- gpuProfile fields are immutable."
  az aks nodepool show -g "$CAP_RG" --cluster-name "$CAP_CLUSTER" -n "$CAP_NODEPOOL" --query gpuProfile -o json
  exit 0
fi

info "Expect 10-20 minutes. Large GPU nodes take longer to provision than NC/NV."

MANAGED_ARGS=""
if [ "$CAP_MANAGED_GPU" = "true" ]; then
  MANAGED_ARGS="--enable-managed-gpu=true"
  info "Attempting the managed GPU stack on ND-series (unverified on this family)."
else
  info "CAP_MANAGED_GPU=false -- using the documented driver-only default."
fi

# shellcheck disable=SC2086
if az aks nodepool add \
     --resource-group "$CAP_RG" \
     --cluster-name "$CAP_CLUSTER" \
     --name "$CAP_NODEPOOL" \
     --node-count "$CAP_NODE_COUNT" \
     --node-vm-size "$CAP_SKU" \
     --node-taints "$LAB_GPU_TAINT" \
     $MANAGED_ARGS \
     -o none; then
  ok "Node pool '$CAP_NODEPOOL' created"
else
  fail "Node pool creation failed."
  info "If the error mentions the managed GPU flag, retry with:"
  info "  CAP_MANAGED_GPU=false $0"
  info "If it says AllocationFailed, the region has no capacity right now."
  exit 1
fi

step "gpuProfile on the H100 pool"
az aks nodepool show -g "$CAP_RG" --cluster-name "$CAP_CLUSTER" -n "$CAP_NODEPOOL" --query gpuProfile -o json

step "Next"
info "Run scripts/62-install-kuberay.sh"
