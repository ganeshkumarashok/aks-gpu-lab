# Module 3 — Verify the managed stack

This module assumes [Module 1](01-cluster.md) (cluster) and
[Module 2](02-managed-gpu-nodepool.md) (managed GPU node pool) are complete,
and that `kubectl` and the `az` CLI are pointed at the lab cluster.

```bash
./scripts/30-verify-managed-stack.sh t4
```

The argument selects which node pool from Module 2 to check: `t4` (pool
`gpunp`), `a10` (pool `infnp`), or `a100` (pool `a100np`). Pool names,
resource group, and cluster name come from `scripts/lib.sh`. See
[Module 2](02-managed-gpu-nodepool.md#resource-group-cluster-node-pool-name-and-sku)
to override them for your subscription.

Six checks run against the pool you pick. On a self-managed GPU node pool you
would have to install the device plugin and DCGM yourself before any of them
could pass. Here they should pass on a node pool you created in Module 2.

The script locates one node in the pool with `kubectl get nodes -l
agentpool=<pool>` and stores its name as `$GPU_NODE`. The commands below
assume that variable is set the same way. To set it yourself, for the `t4`
tier:

```bash
export GPU_NODE=$(kubectl get nodes -l agentpool=gpunp -o jsonpath='{.items[0].metadata.name}')
```

Swap `gpunp` for `infnp` or `a100np` if you are checking a different tier.

## What each check proves

**1. Driver: `gpuProfile.nvidia.managementMode`.**

```bash
az aks nodepool show \
  --resource-group "$LAB_RG" \
  --cluster-name "$LAB_CLUSTER" \
  --name gpunp \
  --query gpuProfile
```

This reads the driver state from the Azure API, not a node label. An
`accelerator=nvidia` label, if you added one yourself, proves nothing: AKS
does not set it. The real driver test is check 5, where a container talks to
the hardware. Use the pool name for the tier you are checking (`gpunp`,
`infnp`, or `a100np`).

**2. Device plugin: `nvidia.com/gpu` in allocatable.**

```bash
kubectl get node "$GPU_NODE" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'
```

A Kubernetes device plugin is what lets the kubelet advertise specialized
hardware, a GPU in this case, as a resource pods can request. This is the
single most important check: it is the difference between "the node has a
GPU" and "Kubernetes can schedule onto it." On a *Driver only* pool this is
empty even though the driver is fine.

**3. DCGM exporter: the node label.**

```bash
kubectl get node "$GPU_NODE" \
  -o jsonpath='{.metadata.labels.kubernetes\.azure\.com/dcgm-exporter}'
# enabled
```

DCGM (NVIDIA Data Center GPU Manager) is NVIDIA's GPU management and
monitoring stack; dcgm-exporter exposes its metrics for Prometheus to scrape.
This label is only present on a `--enable-managed-gpu=true` pool.

**4. NPD health conditions.** NPD (Node Problem Detector) is a Kubernetes
component that watches for node-level hardware and software problems and
reports them as node conditions. Two GPU-specific conditions matter here:

| Condition | Healthy value |
|---|---|
| `UnhealthyNvidiaDevicePlugin` | `False` |
| `UnhealthyNvidiaDCGMServices` | `False` |

Read the polarity carefully: these conditions assert *unhealthiness*, so
`False` is good and `True` is the alarm.

> **Expect this check to warn.** On a node pool created with
> `--enable-managed-gpu=true` and nothing else, these conditions **do not
> appear**: Node Problem Detector is not installed on the node. The docs list
> GPU health as the fourth managed component, but NPD ships via the AKS VM
> extension, which is not present on such a node pool. The script reports
> this as a warning rather than a failure, since it is not something you did
> wrong. See [accuracy notes D6](../docs/accuracy.md).

**5. A container reaches the GPU.** Runs `nvidia-smi` inside a smoke-test pod
with `nvidia.com/gpu: 1` and the `sku=gpu` toleration. The output shows the
device, driver version, and CUDA version, proving the whole path end to end.

**6. DCGM metrics are live.** Reads `http://localhost:19400/metrics` from a
`hostNetwork` pod on the GPU node and asserts `DCGM_FI_DEV_GPU_UTIL` is
present.

## When a check fails

| Symptom | Likely cause |
|---|---|
| `No node found with label agentpool=...` | wrong tier argument, or that tier's pool from Module 2 was never created |
| `nvidia.com/gpu` absent | pool created without `--enable-managed-gpu=true` |
| dcgm-exporter label absent | same |
| smoke-test pod `Pending` | missing toleration for `sku=gpu:NoSchedule` |
| NPD condition `True` | real GPU or driver fault: check `kubectl describe node` |
| NPD condition missing | expected: NPD is not installed (see D6), not a fault |

## Next

[Module 4 — Runtime telemetry](04-observability.md)
