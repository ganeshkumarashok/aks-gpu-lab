# Module 4 — Runtime telemetry

This is where the managed experience pays off most. The DCGM exporter is already
running and already labelled, so instead of spending this module installing a
metrics stack, you spend it learning what to actually look at.

## Two metric sources, two different questions

Once you deploy a workload (module 5) you will have both of these. They are not
redundant — mixing them up is the most common GPU-performance mistake.

| Source | Port | Answers |
|---|---|---|
| **DCGM exporter** | `19400` | Is the *GPU* busy? Utilization, memory, power, temperature, throttling |
| **vLLM / your app** | `8000` | Is the *server* busy? Queue depth, tokens/sec, time-to-first-token |

A GPU pinned at 100% utilization with a server doing 3 requests/second is a
bad sign, not a good one. Neither number means anything alone.

## Reading DCGM directly

The exporter listens on the node, so read it from a pod on that node:

```bash
kubectl run dcgm-probe --rm -i --restart=Never \
  --image=mcr.microsoft.com/azurelinux/base/core:3.0 \
  --overrides='{"spec":{"hostNetwork":true,"tolerations":[{"key":"sku","operator":"Equal","value":"gpu","effect":"NoSchedule"}]}}' \
  -- curl -s http://localhost:19400/metrics | grep '^DCGM_FI_DEV'
```

## The metrics that matter

| Metric | What it tells you | NC (T4/A100) | NV (A10) |
|---|---|---|---|
| `DCGM_FI_DEV_GPU_UTIL` | percent of time the GPU had work queued | yes | present (values not validated) |
| `DCGM_FI_DEV_FB_USED` | framebuffer memory used — predicts OOM | yes | yes |
| `DCGM_FI_DEV_FB_FREE` | headroom before OOM | yes | yes |
| `DCGM_FI_DEV_GPU_TEMP` | temperature in °C | yes | **absent** |
| `DCGM_FI_DEV_POWER_USAGE` | watts; near cap with low util = power-throttled | yes | **absent** |
| `DCGM_FI_PROF_GR_ENGINE_ACTIVE` | graphics/compute engine actually active | yes | **absent** |
| `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE` | tensor-core utilisation — the real number for LLM serving | yes | **absent** |
| `DCGM_FI_PROF_DRAM_ACTIVE` | memory-bandwidth pressure | yes | **absent** |

> **The SKU family decides what you can measure.** Measured on one cluster:
> `NC4as_T4_v3` exports **20** DCGM fields, `NC24ads_A100_v4` exports **23**, and
> `NV36ads_A10_v5` exports **11**. NV-series
> is the visualisation family and runs a GRID **vGPU** profile
> (`NVIDIA A10-24Q`), where the guest cannot read real hardware counters —
> Look for `DCGM_FI_DEV_VGPU_LICENSE_STATUS` to tell you that you are on one.
>
> On A100 you additionally get HBM row-remapping counters
> (`DCGM_FI_DEV_ROW_REMAP_FAILURE` and friends) — a real signal that the GPU
> hardware is degrading, not just busy.
>
> **If GPU telemetry matters to you, choose NC-series over NV-series.** The
> managed stack installs correctly on both; the hardware mode limits what it can
> report. See [accuracy notes](../docs/accuracy.md).

> **Documentation defect.** `monitor-gpu-metrics.md` lists the temperature metric
> as `DCGM_FI_DEV_TEMPERATURE`. That field does not exist — NVIDIA's own
> `default-counters.csv` ships `DCGM_FI_DEV_GPU_TEMP`. A query against the
> documented name silently returns nothing. See
> [accuracy notes D1](../docs/accuracy.md).

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
was not idle — it was waiting on memory, which is exactly what token-by-token
decode does. If you tuned this workload by watching `GPU_UTIL` alone you would
conclude it was saturated and stop. The profiling counters tell you there is
headroom, and that the constraint is bandwidth rather than compute.

That gap is the reason to care which SKU family you are on: on a vGPU node those
three rows do not exist at all.

> **Measuring correctly.** If your probe pod uses `hostNetwork: true`, it also
> needs `dnsPolicy: ClusterFirstWithHostNet` — otherwise it uses the node's
> resolver, cannot resolve `*.svc.cluster.local`, and your load generator
> silently sends nothing. The metrics will look plausible and be idle readings.
> Always confirm the endpoint returns HTTP 200 before trusting a measurement.

## Health versus performance

DCGM tells you how hard the GPU is working. NPD tells you whether it is *broken*:

```bash
kubectl get node "$GPU_NODE" -o json \
  | jq '.status.conditions[] | select(.type|startswith("UnhealthyNvidia"))'
```

`UnhealthyNvidiaDevicePlugin` and `UnhealthyNvidiaDCGMServices` should both be
`False`. These flip on a node that has *stopped* being able to serve GPU
workloads — which otherwise shows up as pods mysteriously failing to schedule.

> **In practice, expect these to be absent.** Verified 2026-09-01: a node pool
> created with `--enable-managed-gpu=true` has no Node Problem Detector
> installed, so neither condition is reported. Until that changes, DCGM is your
> health signal as well as your performance signal — watch
> `DCGM_FI_DEV_XID_ERRORS` in particular, since XID faults are exactly the class
> of failure the NPD conditions were meant to surface. See
> [accuracy notes D6](../docs/accuracy.md).

## Scraping into Azure Managed Prometheus

The exporter emits standard Prometheus format on a labelled node, so the managed
Prometheus addon can scrape it with a pod annotation or a scrape config
targeting `kubernetes.azure.com/dcgm-exporter=enabled`. See
`monitor-gpu-metrics.md` for the addon wiring.

## Next

[Module 5 — Serve a model](05-inference-vllm.md)
