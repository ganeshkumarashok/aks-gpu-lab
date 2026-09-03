#!/usr/bin/env bash
# Module 9 (capstone) -- create the swedencentral cluster.
#
# Separate from the modules 0-5 cluster because the H100 RDMA SKU has quota only
# in swedencentral, and swedencentral has no T4 or A10 quota. Two regions is
# forced by capacity, not by design.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

step "Capstone cluster: $CAP_CLUSTER in $CAP_LOCATION"

if az group show --name "$CAP_RG" >/dev/null 2>&1; then
  ok "Resource group $CAP_RG already exists"
else
  az group create --name "$CAP_RG" --location "$CAP_LOCATION" -o none
  ok "Created resource group $CAP_RG"
fi

if az aks show --resource-group "$CAP_RG" --name "$CAP_CLUSTER" >/dev/null 2>&1; then
  ok "Cluster $CAP_CLUSTER already exists -- skipping create"
else
  info "This takes roughly 8-12 minutes."
  az aks create \
    --resource-group "$CAP_RG" \
    --name "$CAP_CLUSTER" \
    --location "$CAP_LOCATION" \
    --node-count 2 \
    --node-vm-size Standard_D8s_v5 \
    --nodepool-name system \
    --generate-ssh-keys \
    --enable-managed-identity \
    -o none
  ok "Created cluster $CAP_CLUSTER"
fi

az aks get-credentials --resource-group "$CAP_RG" --name "$CAP_CLUSTER" --overwrite-existing -o none
ok "kubeconfig context set to $CAP_CLUSTER"
kubectl get nodes -o wide

step "Next"
info "Run scripts/61-capstone-h100-nodepool.sh"
