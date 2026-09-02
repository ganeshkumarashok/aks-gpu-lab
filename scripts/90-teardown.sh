#!/usr/bin/env bash
# Teardown. GPU nodes are the expensive part of this lab -- run this when done.
#
# Default deletes the whole resource group. Pass --gpu-only to drop just the GPU
# node pools and keep the cluster for later.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

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
