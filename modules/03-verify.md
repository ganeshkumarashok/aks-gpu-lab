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

> **Presence varies by node pool.** On this lab's `t4` pool
> (`Standard_NC4as_T4_v3`), neither condition appears: Node Problem Detector
> is not installed on the node, and the script reports a warning rather than
> a failure. On the `a100` pool (`NC24ads_A100_v4`), the full NPD set is
> present, including these two conditions plus `XIDError` and `GPUMissing`
> (this check only asserts the two listed above). The `a10` pool has not been
> verified either way. Do not assume from the SKU; run the check and read
> what comes back. See [accuracy notes D6](../docs/accuracy.md).

**5. A container reaches the GPU.** Runs `nvidia-smi` inside a smoke-test pod
with `nvidia.com/gpu: 1` and the `sku=gpu` toleration. The output shows the
device, driver version, and CUDA version.

> **`nvidia-smi` alone is not proof.** It queries through NVML, which is a
> separate path from CUDA context creation. A node can enumerate its GPUs
> correctly through NVML while every CUDA workload on it fails. Observed on this
> lab's own cluster:
>
> ```
> $ nvidia-smi -L
> GPU 0: NVIDIA A100 80GB PCIe (UUID: GPU-a445d19d-...)    # passes
>
> Failed to get device capability: No CUDA GPUs are available.
> RuntimeError: No CUDA GPUs are available                  # the real state
> ```
>
> A check that only runs `nvidia-smi` reports such a node as healthy. To
> confirm the GPU is usable, allocate memory on it:
>
> ```bash
> python3 -c "import torch; torch.zeros(8, device='cuda'); print('CUDA_OK')"
> ```

**6. DCGM metrics are live.** Reads `http://localhost:19400/metrics` from a
`hostNetwork` pod on the GPU node and asserts `DCGM_FI_DEV_GPU_UTIL` is
present.

## CrashLoopBackOff on a newly joined node

Check 5 above can pass, and a workload scheduled onto the same node minutes
later can still crashloop with `No CUDA GPUs are available`. This is not a
hardware fault. It is a race on nodes that have just joined the cluster: the
node advertises `nvidia.com/gpu` and becomes schedulable before the device
plugin has finished passing the device into a container. A pod that lands in
that window fails immediately, and `restartPolicy: Always` then restarts the
same container against the same stale allocation instead of triggering a
reschedule, so it crashloops.

Delete the pod:

```bash
kubectl delete pod -n <namespace> <pod-name>
```

The next scheduling decision lands after the device plugin has caught up, or
on a different node, and the workload starts normally.

Reimaging the node and replacing the underlying VM instance were both tried
against this failure and did not fix it. Three separate freshly created
`NC24ads_A100_v4` nodes reproduced the crashloop; a replica scheduled onto an
already-settled node in the same pool ran 7.5 hours without issue. Scaling a
node pool and deploying onto it in the same step reliably produces this
crashloop on the new nodes, and the symptom looks like an application bug
rather than a scheduling race.

## When a check fails

| Symptom | Likely cause |
|---|---|
| `No node found with label agentpool=...` | wrong tier argument, or that tier's pool from Module 2 was never created |
| `nvidia.com/gpu` absent | pool created without `--enable-managed-gpu=true` |
| dcgm-exporter label absent | same |
| smoke-test pod `Pending` | missing toleration for `sku=gpu:NoSchedule` |
| NPD condition `True` | real GPU or driver fault: check `kubectl describe node` |
| NPD condition missing | normal on the `t4` pool: NPD is not installed there (see D6); not necessarily true for other pools |
| Check 5 passed, but a workload on the same node later crashloops with `No CUDA GPUs are available` | freshly joined node: delete the pod, see [above](#crashloopbackoff-on-a-newly-joined-node) |

## Next

[Module 4: Observability](04-observability.md)
