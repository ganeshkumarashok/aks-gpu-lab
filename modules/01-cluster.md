# Module 1: Cluster and production add-ons

```bash
./scripts/10-create-cluster.sh
```

Roughly 8-12 minutes for the cluster, plus several more for the add-ons.

## What it builds

An AKS cluster with a CPU-only system node pool of two `Standard_D4s_v5` nodes.
No GPUs yet.

GPU nodes are added in module 2, in their own pool. Keeping system pods off GPU
nodes has two consequences that matter later: GPU capacity can be deleted and
recreated without disturbing anything else, and cluster add-ons do not consume
GPU memory or occupy a GPU node that a replica needs.

## Add-ons the later modules depend on

```bash
az aks update --resource-group "$LAB_RG" --name "$LAB_CLUSTER" \
  --enable-blob-driver \
  --enable-keda \
  --enable-azure-monitor-metrics \
  --enable-workload-identity \
  --enable-oidc-issuer
```

| Add-on | Used by | AKS documentation |
|---|---|---|
| Blob CSI driver | module 5, shared model storage | [Azure Blob storage CSI driver](https://learn.microsoft.com/azure/aks/azure-blob-csi) |
| Azure Monitor metrics | module 4, DCGM and vLLM metrics | [Managed Prometheus](https://learn.microsoft.com/azure/azure-monitor/essentials/prometheus-metrics-overview) |
| KEDA | module 8, scaling on queue depth | [KEDA add-on](https://learn.microsoft.com/azure/aks/keda-about) |
| Workload identity | KEDA's access to the metrics endpoint | [Workload identity](https://learn.microsoft.com/azure/aks/workload-identity-overview) |
| OIDC issuer | required by workload identity | same |

Application routing, which provides the gateway in module 7, is enabled
separately:

```bash
az aks approuting enable --resource-group "$LAB_RG" --name "$LAB_CLUSTER"
```

Enabling `--enable-azure-monitor-metrics` creates an Azure Monitor workspace if
one does not exist. It appears in a separate resource group named
`DefaultResourceGroup-<region>` and is not removed when this lab's resource
group is deleted.

## Verify

```bash
kubectl get nodes -o wide
```

Two `Ready` nodes in the `system` pool, and no GPU resources anywhere yet:

```bash
kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}'
```

That output is empty. Module 2 changes it with one flag.

Confirm the add-ons landed:

```bash
az aks show --resource-group "$LAB_RG" --name "$LAB_CLUSTER" \
  --query '{blob:storageProfile.blobCsiDriver.enabled, keda:workloadAutoScalerProfile.keda.enabled, prometheus:azureMonitorProfile.metrics.enabled, workloadIdentity:securityProfile.workloadIdentity.enabled}'
```

All four report `true`. Enabling several add-ons in one update takes longer than
the cluster creation itself; the operation reports `ReconcilingAddons` while it
works.

## Next

[Module 2: GPU capacity](02-managed-gpu-nodepool.md)
