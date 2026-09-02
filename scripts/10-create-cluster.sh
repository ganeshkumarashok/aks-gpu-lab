#!/usr/bin/env bash
# Module 1 -- create the AKS cluster and a CPU system node pool.
# No GPU yet: GPU capacity is added in 20-add-managed-gpu-nodepool.sh so the
# expensive resource has the shortest possible lifetime.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

step "Creating resource group $LAB_RG in $LAB_LOCATION"
if az group show --name "$LAB_RG" >/dev/null 2>&1; then
  ok "Resource group $LAB_RG already exists"
else
  az group create --name "$LAB_RG" --location "$LAB_LOCATION" -o none
  ok "Created resource group $LAB_RG"
fi

step "Creating AKS cluster $LAB_CLUSTER"
if az aks show --resource-group "$LAB_RG" --name "$LAB_CLUSTER" >/dev/null 2>&1; then
  ok "Cluster $LAB_CLUSTER already exists -- skipping create"
else
  info "This takes roughly 8-12 minutes."
  # The system pool is CPU-only and small. GPU nodes never run system pods, so
  # the GPU pool can be deleted and recreated without disturbing them.
  az aks create \
    --resource-group "$LAB_RG" \
    --name "$LAB_CLUSTER" \
    --location "$LAB_LOCATION" \
    --node-count 2 \
    --node-vm-size Standard_D4s_v5 \
    --nodepool-name system \
    --generate-ssh-keys \
    --enable-managed-identity \
    -o none
  ok "Created cluster $LAB_CLUSTER"
fi

step "Fetching credentials"
az aks get-credentials --resource-group "$LAB_RG" --name "$LAB_CLUSTER" --overwrite-existing -o none
ok "kubeconfig context set to $LAB_CLUSTER"

kubectl get nodes -o wide
step "Next"
info "Run scripts/20-add-managed-gpu-nodepool.sh"
