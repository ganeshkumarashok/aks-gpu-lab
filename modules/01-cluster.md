# Module 1 — Create the cluster

```bash
./scripts/10-create-cluster.sh
```

Typically 8–12 minutes.

## What it builds

An Azure Kubernetes Service (AKS) cluster with a CPU-only **system node
pool**: two general-purpose `Standard_D4s_v5` nodes. No GPU capacity yet.

Every AKS cluster needs at least one system node pool to run core cluster
components such as CoreDNS and metrics-server. GPU capacity is added as a
separate node pool in the next module, and is kept off this one for two
reasons:

- GPU nodes are the entire cost of this lab. Keeping them in their own pool
  means that pool can be deleted and recreated without touching the cluster
  or its system pods.
- A node pool's managed GPU profile (`driver`, `managementMode`,
  `migStrategy`) is immutable once created (see
  [Module 2](02-managed-gpu-nodepool.md)). Deleting and recreating the pool is
  the standard fix for a wrong flag, which only works cleanly if the pool
  carries no system pods.

### Region, resource group, and cluster name

These come from `scripts/lib.sh` and default to region `westus2`, resource
group `aks-gpu-lab-rg`, and cluster name `aks-gpu-lab`. Override any of them
by exporting `LAB_LOCATION`, `LAB_RG`, or `LAB_CLUSTER` before running the
script, for example if `westus2` does not suit your subscription.

The system pool's VM size, `Standard_D4s_v5`, is fixed in
`scripts/10-create-cluster.sh` rather than read from an environment variable,
and is not covered by the quota and SKU-availability checks in
[Module 0](00-prerequisites.md) (those check the GPU SKUs only). If cluster
creation fails on quota or SKU availability, edit `--node-vm-size` in that
script to a general-purpose size available in your region and subscription.

### Cost

The system pool bills for as long as the cluster exists, including after
`scripts/90-teardown.sh --gpu-only` removes the GPU node pool. Run
`scripts/90-teardown.sh` with no flag to delete the cluster and resource group
entirely and stop that cost too.

## Verify

```bash
kubectl get nodes -o wide
```

Two `Ready` nodes in the `system` pool. No `nvidia.com/gpu` anywhere yet:

```bash
kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}'
# (empty)
```

That empty output is the baseline. The next module changes it with one flag.

## Next

[Module 2 — Managed GPU node pool](02-managed-gpu-nodepool.md)
