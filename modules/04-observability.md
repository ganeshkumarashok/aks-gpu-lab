# Module 4 — Runtime telemetry

NVIDIA Data Center GPU Manager (DCGM) and its exporter are already running on
the managed GPU node pool, labelled and reachable on port `19400`. This module
does not install a metrics pipeline; it reads the metrics that are already
there and explains which ones to look at.

## Before you begin

This module assumes the managed GPU node pool from
[Module 2](02-managed-gpu-nodepool.md) exists and has passed the checks in
[Module 3](03-verify.md). The commands below target a specific node, so set
`$GPU_NODE` first:

```bash
export GPU_NODE=$(kubectl get nodes -l agentpool=gpunp -o jsonpath='{.items[0].metadata.name}')
```

Replace `gpunp` with the node pool you want to inspect: `infnp` for the A10
pool, `a100np` for the A100 pool.

## Two metric sources, two different questions

Once the service is deployed in module 6 you will have both of these. They answer
different questions, and confusing them leads to the wrong conclusion: a GPU
can be fully utilized while the server behind it is barely serving requests,
or the reverse.

| Source | Port | Answers |
|---|---|---|
| **DCGM exporter** | `19400` | Is the *GPU* busy? Utilization, memory, power, temperature, throttling |
| **vLLM / your app** | `8000` | Is the *server* busy? Queue depth, tokens/sec, time-to-first-token |

A GPU pinned at 100% utilization with a server doing 3 requests/second is a
bad sign, not a good one. Neither number means anything alone.

The combinations worth recognising:

| Device | Service | Reading |
|---|---|---|
| high | high | working as intended |
| high | low | stalled: small batches, or memory-bound decode |
| low | low | idle, or bottlenecked before the GPU |
| low | high | short prompts; the GPU is not the constraint |

## Reading DCGM directly

The exporter listens on the node, so read it from a pod on that node:

```bash
kubectl run dcgm-probe --rm -i --restart=Never \
  --image=mcr.microsoft.com/azurelinux/base/core:3.0 \
  --overrides='{"spec":{"hostNetwork":true,"tolerations":[{"key":"sku","operator":"Equal","value":"gpu","effect":"NoSchedule"}]}}' \
  -- curl -s http://localhost:19400/metrics | grep '^DCGM_FI_'
```

## The metrics that matter

| Metric | What it tells you | NC (T4/A100) | NV (A10) |
|---|---|---|---|
| `DCGM_FI_DEV_GPU_UTIL` | percent of time the GPU had work queued | yes | present (values not validated) |
| `DCGM_FI_DEV_FB_USED` | framebuffer memory used; predicts an out-of-memory (OOM) condition | yes | yes |
| `DCGM_FI_DEV_FB_FREE` | headroom before OOM | yes | yes |
| `DCGM_FI_DEV_GPU_TEMP` | temperature in °C | yes | **absent** |
| `DCGM_FI_DEV_POWER_USAGE` | watts; near cap with low util = power-throttled | yes | **absent** |
| `DCGM_FI_PROF_GR_ENGINE_ACTIVE` | graphics/compute engine active | yes | **absent** |
| `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE` | tensor-core (matrix-multiply unit) utilization: the metric that best reflects LLM-serving load | yes | **absent** |
| `DCGM_FI_PROF_DRAM_ACTIVE` | memory-bandwidth pressure | yes | **absent** |

The `DCGM_FI_PROF_*` fields are called profiling counters because they come
from the GPU's own hardware performance-monitoring unit, not from simple
polled state. That is also why they are absent on a vGPU node: the guest does
not have access to that hardware.

> **The SKU family decides what you can measure.** Measured on one cluster:
> `NC4as_T4_v3` exports **20** DCGM fields, `NC24ads_A100_v4` exports **23**, and
> `NV36ads_A10_v5` exports **11**. NC-series is the compute family; NV-series is
> the visualization family and runs an NVIDIA GRID virtual GPU (vGPU) profile
> (`NVIDIA A10-24Q`), in which the guest cannot read the real hardware
> counters. `DCGM_FI_DEV_VGPU_LICENSE_STATUS` is the field to check for to
> confirm you are on one.
>
> On A100 you additionally get high-bandwidth memory (HBM) row-remapping
> counters (`DCGM_FI_DEV_ROW_REMAP_FAILURE` and the related correctable and
> uncorrectable remapped-row counters), a signal of hardware degradation,
> distinct from ordinary utilization.
>
> **If GPU telemetry matters to you, choose NC-series over NV-series.** The
> managed stack installs correctly on both; the hardware mode limits what it
> can report. See [accuracy notes](../docs/accuracy.md).

> **Metric name.** The temperature field is `DCGM_FI_DEV_GPU_TEMP`, matching
> NVIDIA's own `default-counters.csv`. A query for `DCGM_FI_DEV_TEMPERATURE` (a
> name that appears in some AKS documentation) returns no data. See
> [accuracy notes D1](../docs/accuracy.md) for detail.

## What the numbers look like in practice

Measured on `NC24ads_A100_v4` serving Qwen2.5-7B under 12 concurrent requests:

| Metric | Idle | Under load |
|---|---|---|
| `DCGM_FI_DEV_GPU_UTIL` | 0 | 100 |
| `DCGM_FI_DEV_POWER_USAGE` | 90.9 W | 299.1 W |
| `DCGM_FI_PROF_GR_ENGINE_ACTIVE` | 0.000 | 0.362 |
| `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE` | 0.000 | 0.097 |
| `DCGM_FI_PROF_DRAM_ACTIVE` | 0.000 | 0.244 |

**Read those last three rows carefully.** `GPU_UTIL` says 100%. But the graphics
engine was active only 36% of the time, and the tensor cores only 9.7%. The GPU
was not idle. It was waiting on memory, which is exactly what token-by-token
decode does. If you tuned this workload by watching `GPU_UTIL` alone you would
conclude it was saturated and stop. The profiling counters tell you there is
headroom, and that the constraint is bandwidth rather than compute.

That gap is the reason to care which SKU family you are on: on a vGPU node those
three rows do not exist at all.

> **Measuring correctly.** If your probe pod uses `hostNetwork: true`, it also
> needs `dnsPolicy: ClusterFirstWithHostNet`. Otherwise it uses the node's
> resolver, cannot resolve `*.svc.cluster.local`, and your load generator never
> reaches the server. The metrics will look plausible while reflecting an idle
> GPU. Always confirm the endpoint returns HTTP 200 before trusting a
> measurement.

## Health versus performance

DCGM tells you how hard the GPU is working. Node Problem Detector (NPD) tells
you whether it is *broken*:

```bash
kubectl get node "$GPU_NODE" -o json \
  | jq '.status.conditions[] | select(.type|startswith("UnhealthyNvidia"))'
```

`UnhealthyNvidiaDevicePlugin` and `UnhealthyNvidiaDCGMServices` should both be
`False`. These flip on a node that has *stopped* being able to serve GPU
workloads, which otherwise shows up as pods failing to schedule with no
obvious cause.

> **Presence varies by node pool.** On an `NC4as_T4_v3` pool created with
> `--enable-managed-gpu=true`, neither condition is reported; the same is true
> on the ND-series pools used in [Module 9](09-capstone-multinode.md). On an
> `NC24ads_A100_v4` pool in the same subscription and region, both conditions
> are present and reporting. Check the node directly rather than assuming
> either way:
>
> ```bash
> kubectl get node "$GPU_NODE" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}'
> ```
>
> Where the conditions are absent, DCGM is the health signal as well as the
> performance signal. Watch `DCGM_FI_DEV_XID_ERRORS` in particular: XID codes
> are the GPU driver's hardware-error identifiers, and they are the class of
> failure the NPD conditions are meant to surface. See
> [accuracy notes D6](../docs/accuracy.md).

## Scraping into Azure Managed Prometheus

The exporter emits standard Prometheus format on a labelled node, so the managed
Prometheus addon can scrape it with a pod annotation or a scrape config
targeting `kubernetes.azure.com/dcgm-exporter=enabled`. See
`monitor-gpu-metrics.md` for the addon wiring.

## Next

[Module 5: Model storage](05-model-storage.md)
