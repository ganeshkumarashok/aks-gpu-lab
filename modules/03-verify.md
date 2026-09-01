# Module 3 — Verify the managed stack

```bash
./scripts/30-verify-managed-stack.sh t4
```

Six checks. On a self-managed GPU node pool you would have to install the device
plugin and DCGM yourself before any of them could pass; here they should pass on
a node pool you just created.

## What each check proves

**1. Driver — `accelerator` node label.** Informational. The real driver test is
check 5, where a container actually talks to the hardware.

**2. Device plugin — `nvidia.com/gpu` in allocatable.**

```bash
kubectl get node "$GPU_NODE" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'
```

This is the single most important check. It is the difference between "the node
has a GPU" and "Kubernetes can schedule onto it." On a *Driver only* pool this
is empty even though the driver is fine.

**3. DCGM exporter — the node label.**

```bash
kubectl get node "$GPU_NODE" \
  -o jsonpath='{.metadata.labels.kubernetes\.azure\.com/dcgm-exporter}'
# enabled
```

Only present on a `--enable-managed-gpu=true` pool.

**4. NPD health conditions.** Two GPU-specific node conditions:

| Condition | Healthy value |
|---|---|
| `UnhealthyNvidiaDevicePlugin` | `False` |
| `UnhealthyNvidiaDCGMServices` | `False` |

Read the polarity carefully — these assert *unhealthiness*, so `False` is good
and `True` is the alarm.

> **Expect this check to warn.** On a node pool created with
> `--enable-managed-gpu=true` and nothing else, these conditions **do not
> appear** — Node Problem Detector is not installed on the node. The docs list
> GPU health as the fourth managed component, but NPD ships via the AKS VM
> extension, which is not present on such a node pool. The script reports this
> as a warning rather than a failure because nothing you did caused it. See
> [accuracy notes D6](../docs/accuracy.md).

**5. A container reaches the GPU.** Runs `nvidia-smi` inside a pod with
`nvidia.com/gpu: 1` and the `sku=gpu` toleration. The output shows the device,
driver version, and CUDA version — proving the whole path end to end.

**6. DCGM metrics are live.** Reads `http://localhost:19400/metrics` from a
`hostNetwork` pod on the GPU node and asserts `DCGM_FI_DEV_GPU_UTIL` is present.

## When a check fails

| Symptom | Likely cause |
|---|---|
| `nvidia.com/gpu` absent | pool created without `--enable-managed-gpu=true` |
| dcgm-exporter label absent | same |
| smoke pod `Pending` | missing toleration for `sku=gpu:NoSchedule` |
| NPD condition `True` | genuine GPU or driver fault — check `kubectl describe node` |
| NPD condition missing | expected — NPD is not installed (see D6), not a fault |

## Next

[Module 4 — Runtime telemetry](04-observability.md)
