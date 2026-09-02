# Accuracy notes

Every command in this lab traces to a published Microsoft Learn article in
`azure-aks-docs`. This file records those citations, the version floors, and the
places where the published docs are currently **wrong or self-contradictory** —
so a reader who notices a discrepancy knows it was seen, checked, and decided.

Verified 2026-09-01 against the published AKS documentation on Microsoft Learn
(`MicrosoftDocs/azure-aks-docs`).

## Why this lab is on the preview surface

`gpuProfile.nvidia.managementMode` — the field behind `--enable-managed-gpu` —
exists **only** on preview API versions (`v20260102preview` … `v20260802preview`).
GA API versions run through `v20260801` and none expose it. That is why the
`aks-preview` CLI extension is required and why the feature is documented as
preview, and it is the single fact that determines this lab's prerequisites.

## Version floors

| Requirement | Value | Source | Note |
|---|---|---|---|
| azure-cli | ≥ 2.85.0 | `aks-managed-gpu-nodes.md` "Before you begin" | enforced by `preflight.sh` |
| aks-preview | ≥ 19.0.0b29 | `aks-managed-gpu-nodes.md` | see discrepancy D2 |
| Feature flag | `ManagedGPUExperiencePreview` | `aks-managed-gpu-nodes.md` | see discrepancy D4 |

## The three install profiles

From the install-profile table in `aks-managed-gpu-nodes.md`:

| Profile | Flags | AKS installs |
|---|---|---|
| Full managed stack | `--enable-managed-gpu=true` | driver, device plugin, DCGM exporter, NPD GPU health |
| Driver only (**default**) | `--enable-managed-gpu=false` | driver only |
| None (BYO) | `--enable-managed-gpu=false --gpu-driver None` | nothing |

**Passing no flag gives you Driver only, not the full stack.** This lab always
passes `--enable-managed-gpu=true` explicitly.

## Preview constraints that shape this lab

- **No cluster autoscaler** on managed GPU node pools during preview. Scale with
  `az aks nodepool scale`. This is why no module uses `--enable-cluster-autoscaler`.
- **`managementMode`, `migStrategy`, and `driver` are immutable** after node pool
  creation. A wrong flag costs a delete-and-recreate, so `20-add-managed-gpu-nodepool.sh`
  refuses to silently continue against an existing pool.
- **Linux only.** Windows GPU node pools are a different path (`use-windows-gpu.md`).
- **No in-place migration** from an existing GPU node pool.

## Known documentation defects

Found while building this lab. Each is verified against primary source. None are
worked around silently — the lab uses the correct value and says so here.

**D1 — `DCGM_FI_DEV_TEMPERATURE` does not exist.**
`monitor-gpu-metrics.md` lists it as the GPU temperature metric. The real DCGM
field is `DCGM_FI_DEV_GPU_TEMP`, which is what NVIDIA's own
`dcgm-exporter/etc/default-counters.csv` ships and what `aks-managed-gpu-nodes.md`
and `best-practices-ml-ops.md` both use. A query against the documented name
returns no data. **This lab uses `DCGM_FI_DEV_GPU_TEMP`.**

**D2 — aks-preview minimum is likely 19.0.0b28, not b29.**
`aks-managed-gpu-nodes.md` requires ≥ 19.0.0b29. The extension's own
`HISTORY.rst` logs "Add managed GPU enablement option to node pool property"
under **19.0.0b28**; 19.0.0b29 adds the MIG strategy flags. Since this lab also
covers MIG, the stricter number is harmless and we enforce the documented b29.

**D3 — `--gpu-mig-strategy None` is documented but rejected.**
The article describes the strategy values as `None`, `Single`, `Mixed`. `None`
is the API field's default, not a passable CLI value — the CLI enum is
`Single | Mixed` only. To get no MIG, omit the flag. Passing `None` errors.

**D4 — the feature registration step may be stale.**
The article instructs
`az feature register --namespace Microsoft.ContainerService --name ManagedGPUExperiencePreview`.
Registration is harmless and this lab still performs it to match the documented
flow, but the requirement is worth re-checking against current docs before
relying on it. `preflight.sh` warns rather than fails when the feature is
unregistered, so a subscription without it can still proceed.

**D6 — the NPD GPU health component does not appear on a managed GPU node pool.**
`aks-managed-gpu-nodes.md` lists "GPU health signals" as one of the four
components AKS installs and manages, and its "Verify the managed GPU node pool"
section instructs the reader to confirm that `UnhealthyNvidiaDevicePlugin` and
`UnhealthyNvidiaDCGMServices` both report `False`.

Verified on 2026-09-01, westus2, `Standard_NC4as_T4_v3`, node pool created with
`--enable-managed-gpu=true` and nothing else: **neither condition exists.** The
node reports only the four stock kubelet conditions.

Traced to root cause:

- The other three managed components run as **systemd services on the node**,
  not as Kubernetes DaemonSets — `nvidia-device-plugin.service`,
  `nvidia-dcgm.service`, and `nvidia-dcgm-exporter.service` are all `active
  running`. (This is why the docs describe the device plugin as
  "DaemonSet-equivalent" rather than a DaemonSet, and why `kubectl get ds -A`
  shows nothing GPU-related.)
- `node-problem-detector` is **not installed at all** — no unit file, no
  `/etc/node-problem-detector.d/custom-plugin-monitor/` directory.
- The GPU VMSS carries only two extensions, `vmssCSE` and `AKSLinuxBilling`
  (`az vmss extension list`). Whatever component would normally deliver NPD and
  its GPU plugin configs is not among them on this node pool.

So three of the four advertised components work exactly as documented, and the
fourth is absent through no fault of the reader. This lab therefore treats the
NPD conditions as a **warning, not a failure**, and says why. Whether NPD
requires an additional addon, is region-gated, or is still rolling out is not
determinable from public documentation.

**D5 — core azure-cli floor for `--gpu-driver` is 2.72.0, not 2.72.2.**
`use-nvidia-gpu.md` and `nvidia-gpu-operator.md` state 2.72.2; azure-cli
`HISTORY.rst` shows the enum landed in 2.72.0. Does not affect this lab, which
requires a much newer CLI anyway.

## Non-documentation gotchas found by running the lab

**Service name collision breaks vLLM.** A `Service` named `vllm` causes
Kubernetes to inject `VLLM_PORT=tcp://<clusterIP>:8000`. vLLM parses `VLLM_PORT`
as its own setting and crashes with `ValueError: VLLM_PORT ... appears to be a
URI` — *after* the model is fully loaded. Fixed with `enableServiceLinks: false`.
Verified 2026-09-01 on `Standard_NV36ads_A10_v5`, vLLM v0.28.0.

**The SKU family decides what you can measure.** All three measured on the same
cluster with the same managed GPU stack, 2026-09-01:

| | `NC4as_T4_v3` | `NV36ads_A10_v5` | `NC24ads_A100_v4` | `ND96isrf_H100_v5` |
|---|---|---|---|---|
| Family | NC (compute) | NV (visualisation) | NC (compute) | ND (compute) |
| Device reported | `Tesla T4` | `NVIDIA A10-24Q` (vGPU) | `NVIDIA A100 80GB PCIe` | `NVIDIA H100 80GB` |
| Driver | 580.159.04 | 570.211.01 (GRID) | 580.159.04 | 580.159.04 |
| CUDA | 13.0 | 12.8 | 13.0 | 13.0 |
| **DCGM fields** | **20** | **11** | **23** | **24** |

H100 adds `DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL` on top of A100's 23 — the metric
you want when tensor parallelism is riding NVLink inside the node.

A100 is a strict superset of T4 — nothing exported on T4 is missing on A100. The
three extra fields are HBM row-remapping counters
(`DCGM_FI_DEV_CORRECTABLE_REMAPPED_ROWS`, `_UNCORRECTABLE_REMAPPED_ROWS`,
`DCGM_FI_DEV_ROW_REMAP_FAILURE`), which exist only on HBM parts and are genuine
hardware-degradation signals.

Present on both NC nodes and **absent** on the NV/A10 node:

```
DCGM_FI_DEV_GPU_TEMP                 DCGM_FI_PROF_GR_ENGINE_ACTIVE
DCGM_FI_DEV_POWER_USAGE              DCGM_FI_PROF_PIPE_TENSOR_ACTIVE
DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION DCGM_FI_PROF_DRAM_ACTIVE
DCGM_FI_DEV_PCIE_REPLAY_COUNTER      DCGM_FI_PROF_PCIE_RX_BYTES / _TX_BYTES
```

The `DCGM_FI_PROF_*` family is the set that actually characterises a serving
workload, so its absence matters more than the count suggests.
`DCGM_FI_DEV_VGPU_LICENSE_STATUS` is the giveaway that you are on a vGPU.

> **Scope of this claim.** The field-set difference above is measured — it comes
> from enumerating what the exporter publishes, which needs no workload. Whether
> the fields the A10 *does* export report meaningful values under load was **not
> validated**: the first attempt used a `hostNetwork` probe pod without
> `dnsPolicy: ClusterFirstWithHostNet`, so it could not resolve the service and
> the load never reached vLLM. Do not read this section as a claim that vGPU
> counters are wrong — only that nine fields, including all profiling counters,
> are absent.

**On A100, the exported counters do respond correctly to load.** Same probe with
DNS fixed, load confirmed by vLLM's own counters
(`vllm:generation_tokens_total 12334`, `request_success_total 13`):

| Metric | Idle | Under load |
|---|---|---|
| `DCGM_FI_DEV_GPU_UTIL` | 0 | 100 |
| `DCGM_FI_DEV_POWER_USAGE` | 90.9 W | 299.1 W |
| `DCGM_FI_PROF_GR_ENGINE_ACTIVE` | 0.000 | 0.362 |
| `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE` | 0.000 | 0.097 |
| `DCGM_FI_PROF_DRAM_ACTIVE` | 0.000 | 0.244 |

Note the gap between `GPU_UTIL` at 100 and `PIPE_TENSOR_ACTIVE` at 0.097. That
is the whole argument for the profiling counters: "100% utilised" means the GPU
had *work queued*, not that it was doing useful math.

**Probe pods that need cluster DNS must set `dnsPolicy: ClusterFirstWithHostNet`.**
A `hostNetwork: true` pod uses the node's resolver by default and cannot resolve
`*.svc.cluster.local`. This silently produces plausible-looking "under load"
readings that are really idle readings. Always assert reachability (check for
HTTP 200) before trusting a load measurement.

**Implication for GPU observability on AKS: choose NC-series (compute) over
NV-series (visualization) when GPU telemetry matters.** The managed stack
installs and runs correctly on both; the hardware/driver mode determines what it
can actually report.

**AKS picks different driver branches per SKU family, silently.** In one cluster:
`Standard_NC4as_T4_v3` got driver 580.159.04 / CUDA 13.0 (`Tesla T4`), while
`Standard_NV36ads_A10_v5` got 570.211.01 / CUDA 12.8 and reported as
`NVIDIA A10-24Q` — a GRID vGPU profile. NC is the compute family, NV the
visualization family, and `gpuProfile.driverType` defaults to system-selected.
Pinning a container image to one CUDA version can therefore behave differently
across node pools in the same cluster.

## SKU and region selection

A VM size is usable only if it clears **both** gates:

1. The Compute REST API (`Microsoft.Compute/skus`) returns an **empty
   `restrictions` array** for it in that region.
2. `az vm list-usage` shows **non-zero quota** for its family.

Checking only one is misleading. westus3 reports T4 quota of 0/300 while the T4
SKU itself is `NotAvailableForSubscription` there — quota you cannot spend.
`preflight.sh` checks both, and hits the REST API directly for gate 1 instead of
`az vm list-skus`: the CLI command filters client-side and measured 7m23s per
call against about 7 seconds for the REST call.

| SKU | Role | GPU |
|---|---|---|
| `Standard_NC4as_T4_v3` | modules 1–4 | 1× T4 16 GB |
| `Standard_NV36ads_A10_v5` | module 5 (vLLM) | 1× A10 24 GB |
| `Standard_NC24ads_A100_v4` | optional MIG module | 1× A100 80 GB |

The taint `sku=gpu:NoSchedule` is a **convention from the docs, not an AKS
default**. AKS does not taint GPU nodes automatically. Every GPU pod in this lab
carries the matching toleration; a pod without one stays Pending with no
obvious cause.

## Capacity and quota behaviour on large GPU SKUs

Measured while provisioning 2x `Standard_ND96isrf_H100_v5` in swedencentral,
2026-09-01. None of this is in the AKS documentation.

**Quota and availability do not imply capacity.** The SKU showed an empty
`restrictions` array and 0/192 family quota — both gates from module 0 passed —
and allocation still failed:

```
AllocationFailed: VM allocation in the Availability Set failed. Allocation for
this Availability Set is constrained (pinned) to a specific cluster, which may
be out of capacity.
```

Retried twice with the same result. There is no API that promises capacity in
advance; the two gates tell you whether you are *allowed* to ask, not whether
you will get it.

**The constraint is per node pool.** Each pool's allocation is pinned to one
physical cluster, so a single 2-node pool can fail where two 1-node pools
succeed. If you need N large GPU nodes and one pool will not fill, splitting
across pools is worth trying before assuming the region is empty. Select
workloads on `node.kubernetes.io/instance-type` rather than `agentpool` so pods
land wherever capacity was actually found.

**Quota is charged against desired count, not running nodes.** A pool with
`count: 2` that only ever provisioned one node still reserves the full 192 vCPU.
Creating a second pool then fails with:

```
ErrCode_InsufficientVCPUQuota: requested 96, remaining 0
```

Scaling the stalled pool down to its real size releases the reservation. Note
also that surge nodes during upgrade consume quota, which is why a pool sized to
exactly your quota ceiling cannot be upgraded with the default `maxSurge`.

**`az aks nodepool update` fails on a managed GPU node pool.** Attempting to add
a label:

```
az aks nodepool update ... --labels gpulab-role=h100
→ (PropertyChangeNotAllowed) Changing property
  'properties.gpuProfile.nvidia.managementMode' is not allowed
```

`managementMode` was never specified on the command line. The update path
appears to send the stored `gpuProfile` back and the RP rejects it against the
immutability rule, so unrelated mutable properties cannot be changed either.
Workaround: label the node directly with `kubectl label node`, accepting that it
does not survive node replacement.

## Out of scope, and why

**Multi-node NVIDIA RDMA / InfiniBand.** Not covered on the golden path. AKS docs
contain zero references to GPUDirect or `nvidia-peermem`, and the only
`AKSInfinibandSupport` documentation is in `use-amd-gpus.md` for AMD MI300X.
There is no published NVIDIA InfiniBand-on-AKS guidance to build on. See
`modules/06-capstone-multinode.md` for how the capstone handles this honestly.
