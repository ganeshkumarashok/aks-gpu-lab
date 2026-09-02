#!/usr/bin/env bash
# Teardown. GPU nodes are the expensive part of this lab -- run this when done.
#
# Usage:
#   90-teardown.sh                      delete the modules 0-5 resource group
#   90-teardown.sh --gpu-only           drop the lab GPU node pools, keep the cluster
#   90-teardown.sh --capstone           delete the capstone resource group (H100)
#   90-teardown.sh --capstone-gpu-only  drop the H100 pool, keep the capstone cluster

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# The capstone lives in a different resource group and region (swedencentral),
# so tearing down the main lab does NOT touch it. 2x ND96isrf_H100_v5 is by far
# the most expensive resource in this repo. Delete it when you are done.
if [ "${1:-}" = "--capstone" ]; then
  step "Deleting the capstone resource group $CAP_RG ($CAP_LOCATION)"
  if ! az group show --name "$CAP_RG" >/dev/null 2>&1; then
    ok "Resource group $CAP_RG does not exist -- nothing to do"
    exit 0
  fi
  warn "This deletes cluster $CAP_CLUSTER and the ${CAP_NODE_COUNT}-node $CAP_SKU pool."
  printf '  Type the resource group name to confirm: '
  read -r confirm
  if [ "$confirm" != "$CAP_RG" ]; then
    fail "Confirmation did not match. Aborted; nothing deleted."
    exit 1
  fi
  az group delete --name "$CAP_RG" --yes --no-wait
  ok "Delete submitted for $CAP_RG (running in background)."
  info "Confirm with: az group show --name $CAP_RG --query properties.provisioningState -o tsv"
  exit 0
fi

if [ "${1:-}" = "--capstone-gpu-only" ]; then
  step "Deleting the capstone H100 node pool only"
  if az aks nodepool show -g "$CAP_RG" --cluster-name "$CAP_CLUSTER" -n "$CAP_NODEPOOL" >/dev/null 2>&1; then
    info "Deleting $CAP_NODEPOOL (this releases the H100 capacity)..."
    az aks nodepool delete -g "$CAP_RG" --cluster-name "$CAP_CLUSTER" -n "$CAP_NODEPOOL" -o none
    ok "Deleted $CAP_NODEPOOL"
  else
    info "Node pool $CAP_NODEPOOL not present"
  fi
  ok "H100 capacity released. Cluster $CAP_CLUSTER still exists."
  exit 0
fi

if [ "${1:-}" = "--gpu-only" ]; then
  step "Deleting GPU node pools only"
  for pool in "$LAB_NODEPOOL_T4" "$LAB_NODEPOOL_A10" "$LAB_NODEPOOL_A100"; do
    if az aks nodepool show -g "$LAB_RG" --cluster-name "$LAB_CLUSTER" -n "$pool" >/dev/null 2>&1; then
      info "Deleting node pool $pool..."
      az aks nodepool delete -g "$LAB_RG" --cluster-name "$LAB_CLUSTER" -n "$pool" -o none
      ok "Deleted $pool"
    else
      info "Node pool $pool not present"
    fi
  done
  ok "GPU capacity released. Cluster $LAB_CLUSTER still exists (and still bills for the system pool)."
  exit 0
fi

# Bare invocation only deletes the modules 0-5 resource group. The capstone RG
# is separate and must be deleted with --capstone.
step "Deleting resource group $LAB_RG"
if ! az group show --name "$LAB_RG" >/dev/null 2>&1; then
  ok "Resource group $LAB_RG does not exist -- nothing to do"
  exit 0
fi

warn "This deletes the cluster, all node pools, and every resource in $LAB_RG."
printf '  Type the resource group name to confirm: '
read -r confirm
if [ "$confirm" != "$LAB_RG" ]; then
  fail "Confirmation did not match. Aborted; nothing deleted."
  exit 1
fi

az group delete --name "$LAB_RG" --yes --no-wait
ok "Delete submitted (running in background)."
info "Track it with: az group show --name $LAB_RG --query properties.provisioningState -o tsv"
