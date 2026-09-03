# Accuracy notes

This document accompanies the [GPU on AKS lab](../README.md). It records the
Microsoft Learn articles each command in this lab traces to, the minimum tool
and extension versions required, and behavior observed while running the lab
against a live Azure subscription. Where a value used in this lab differs from
a published article, the difference and the source checked are noted in
context.

Region names, SKU names, and quota figures below reflect the subscription and
regions used to validate this lab. See
[Adapt region and SKU to your subscription](../modules/00-prerequisites.md#adapt-region-and-sku-to-your-subscription)
in Module 0 to point any of these at your own subscription and region.

Last checked 2026-09-01 against the published AKS documentation in
`MicrosoftDocs/azure-aks-docs`.

## Why this lab is on the preview surface

`gpuProfile.nvidia.managementMode` (the field behind `--enable-managed-gpu`)
exists only on preview API versions (`v20260102preview` … `v20260802preview`).
GA (General Availability) API versions run through `v20260801` and none
expose it. This is why the `aks-preview` CLI extension is required and why
this lab's prerequisites are built around a preview feature.

## Version floors

| Requirement | Value | Source | Note |
|---|---|---|---|
| azure-cli | ≥ 2.85.0 | `aks-managed-gpu-nodes.md` "Before you begin" | enforced by `scripts/preflight.sh` |
| aks-preview | ≥ 19.0.0b29 | `aks-managed-gpu-nodes.md` | see discrepancy D2 |
| Feature flag | `ManagedGPUExperiencePreview` | `aks-managed-gpu-nodes.md` | see discrepancy D4 |

## The three install profiles

From the install-profile table in `aks-managed-gpu-nodes.md`:

| Profile | Flags | AKS installs |
|---|---|---|
| Full managed stack | `--enable-managed-gpu=true` | driver, device plugin, DCGM (NVIDIA Data Center GPU Manager) exporter, NPD (Node Problem Detector) GPU health |
| Driver only (**default**) | `--enable-managed-gpu=false` | driver only |
| None (bring your own) | `--enable-managed-gpu=false --gpu-driver None` | nothing |

**Passing no flag gives you Driver only, not the full stack.** This lab always
passes `--enable-managed-gpu=true` explicitly.

## Preview constraints that shape this lab

- **No cluster autoscaler** on managed GPU node pools during preview. Scale with
  `az aks nodepool scale`. This is why no module uses `--enable-cluster-autoscaler`.
- **`managementMode`, `migStrategy`, and `driver` are immutable** after node pool
  creation. A wrong flag costs a delete-and-recreate, so
  `scripts/20-add-managed-gpu-nodepool.sh` checks for an existing pool with the
  same name and exits without changing anything if one is found, rather than
  attempting to reconfigure it.
- **Linux only.** Windows GPU node pools are a different path (`use-windows-gpu.md`).
- **No in-place migration** from an existing GPU node pool.

## Known documentation defects

Checked against a primary source, such as the extension's release history,
NVIDIA's own reference files, or a live API response, while building this lab.
Each entry states the value this lab uses and why.

**D1: `DCGM_FI_DEV_TEMPERATURE` does not exist.**
`monitor-gpu-metrics.md` lists it as the GPU temperature metric. The real DCGM
field is `DCGM_FI_DEV_GPU_TEMP`, which is what NVIDIA's own
`dcgm-exporter/etc/default-counters.csv` ships and what `aks-managed-gpu-nodes.md`
and `best-practices-ml-ops.md` both use. A query against the documented name
returns no data. **This lab uses `DCGM_FI_DEV_GPU_TEMP`.**

**D2: aks-preview minimum is likely 19.0.0b28, not b29.**
`aks-managed-gpu-nodes.md` requires ≥ 19.0.0b29. The extension's own
`HISTORY.rst` logs "Add managed GPU enablement option to node pool property"
under **19.0.0b28**; 19.0.0b29 adds the MIG (Multi-Instance GPU) strategy
flags. Since this lab also covers MIG, the stricter number is harmless, and
this lab enforces the documented b29 floor.

**D3: `--gpu-mig-strategy None` is documented but rejected.**
The article describes the strategy values as `None`, `Single`, `Mixed`. `None`
is the API field's default, not a passable CLI value. The CLI enum accepts
`Single | Mixed` only. To get no MIG, omit the flag. Passing `None` causes an error.

**D4: the feature registration step may be stale.**
The article instructs
`az feature register --namespace Microsoft.ContainerService --name ManagedGPUExperiencePreview`.
Registration is harmless and this lab still performs it to match the documented
flow, but the requirement is worth re-checking against current docs before
relying on it. `preflight.sh` warns rather than fails when the feature is
unregistered, so a subscription without it can still proceed.

**D5: core azure-cli floor for `--gpu-driver` is 2.72.0, not 2.72.2.**
`use-nvidia-gpu.md` and `nvidia-gpu-operator.md` state 2.72.2; azure-cli
`HISTORY.rst` shows the enum landed in 2.72.0. Does not affect this lab, which
requires a much newer CLI anyway.

**D6: the NPD GPU health component does not appear on every managed GPU node pool.**
`aks-managed-gpu-nodes.md` lists "GPU health signals" as one of the four
components AKS installs and manages, and its "Verify the managed GPU node pool"
section instructs the reader to confirm that `UnhealthyNvidiaDevicePlugin` and
`UnhealthyNvidiaDCGMServices` both report `False`.

**Presence varies by node pool.** Verified on 2026-09-01, westus2,
`Standard_NC4as_T4_v3`, node pool created with `--enable-managed-gpu=true` and
nothing else: **neither condition exists.** The node reports only the four
stock kubelet conditions. The `Standard_ND96isrf_H100_v5` pool used in D7
below showed the same absence. On 2026-09-03, an `NC24ads_A100_v4` pool in
the same subscription and region reported the full NPD set, including
`UnhealthyNvidiaDevicePlugin`, `UnhealthyNvidiaDCGMServices`, `XIDError` and
`GPUMissing`. Check the node rather than assuming either way:

```bash
kubectl get node <node> -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}'
```

On the T4 pool, where the conditions were absent, this traced to:

- The other three managed components run as **systemd services on the node**,
  not as Kubernetes DaemonSets. `nvidia-device-plugin.service`,
  `nvidia-dcgm.service`, and `nvidia-dcgm-exporter.service` are all `active
  running`. (This is why the docs describe the device plugin as
  "DaemonSet-equivalent" rather than a DaemonSet, and why `kubectl get ds -A`
  shows nothing GPU-related.)
- `node-problem-detector` is **not installed at all**: no unit file, no
  `/etc/node-problem-detector.d/custom-plugin-monitor/` directory.
- The GPU node pool's underlying VM Scale Set (VMSS) carries only two
  extensions, `vmssCSE` and `AKSLinuxBilling` (`az vmss extension list`).
  Whatever component would normally deliver NPD and its GPU plugin configs was
  not among them on this node pool.

This lab treats the NPD conditions as a **warning, not a failure**: three of
the four advertised components work exactly as documented, and the fourth is
present on some node pools and absent on others. Whether the difference is
driven by SKU family, region, or rollout timing is not determinable from
public documentation.

## Non-documentation gotchas found by running the lab

**A `Service` named `vllm` breaks vLLM.** Kubernetes injects
`VLLM_PORT=tcp://<clusterIP>:8000` into every pod in a namespace that also has
a `Service` named `vllm`. vLLM reads `VLLM_PORT` as its own setting and
crashes with `ValueError: VLLM_PORT ... appears to be a URI`, after the model
has already finished loading. Set `enableServiceLinks: false` on the pod spec
to avoid it. Verified 2026-09-01 on `Standard_NV36ads_A10_v5`, vLLM v0.28.0.

**The SKU family decides what you can measure.** All four SKUs below were
measured on the same cluster with the same managed GPU stack on 2026-09-01.
The A10 pool runs a GRID vGPU (virtual GPU) profile, NVIDIA's licensed
virtualization mode, rather than passing the physical device through
directly, which is why its field count differs so much from the others:

| | `NC4as_T4_v3` | `NV36ads_A10_v5` | `NC24ads_A100_v4` | `ND96isrf_H100_v5` |
|---|---|---|---|---|
| Family | NC (compute) | NV (visualisation) | NC (compute) | ND (compute) |
| Device reported | `Tesla T4` | `NVIDIA A10-24Q` (vGPU) | `NVIDIA A100 80GB PCIe` | `NVIDIA H100 80GB` |
| Driver | 580.159.04 | 570.211.01 (GRID) | 580.159.04 | 580.159.04 |
| CUDA | 13.0 | 12.8 | 13.0 | 13.0 |
| **DCGM fields** | **20** | **11** | **23** | **24** |

H100 adds `DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL` on top of A100's 23 fields: the
metric to watch when tensor parallelism (splitting a single model's
computation across multiple GPUs) runs over NVLink, NVIDIA's high-bandwidth
GPU-to-GPU interconnect, inside the node.

A100 is a strict superset of T4: nothing exported on T4 is missing on A100.
The three extra fields are HBM (High Bandwidth Memory) row-remapping counters
(`DCGM_FI_DEV_CORRECTABLE_REMAPPED_ROWS`, `_UNCORRECTABLE_REMAPPED_ROWS`,
`DCGM_FI_DEV_ROW_REMAP_FAILURE`), which exist only on HBM parts and indicate
hardware degradation.

Present on both NC nodes and **absent** on the NV/A10 node:

```
DCGM_FI_DEV_GPU_TEMP                 DCGM_FI_PROF_GR_ENGINE_ACTIVE
DCGM_FI_DEV_POWER_USAGE              DCGM_FI_PROF_PIPE_TENSOR_ACTIVE
DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION DCGM_FI_PROF_DRAM_ACTIVE
DCGM_FI_DEV_PCIE_REPLAY_COUNTER      DCGM_FI_PROF_PCIE_RX_BYTES / _TX_BYTES
```

The `DCGM_FI_PROF_*` family is the set that characterises a serving workload,
so its absence matters more than the count suggests. `DCGM_FI_DEV_VGPU_LICENSE_STATUS`
indicates that the node is running a vGPU profile.

> **Scope of this claim.** The field-set difference above is measured: it
> comes from enumerating what the exporter publishes, which requires no
> running workload. Whether the fields the A10 *does* export report
> meaningful values under load was **not validated** — the first attempt used
> a `hostNetwork` probe pod without `dnsPolicy: ClusterFirstWithHostNet`, so it
> could not resolve the service and the load never reached vLLM. This section
> is not a claim that vGPU counters are wrong, only that nine fields,
> including all profiling counters, are absent.

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

Note the gap between `GPU_UTIL` at 100 and `PIPE_TENSOR_ACTIVE` at 0.097. This
is why the profiling counters matter: a `GPU_UTIL` reading of 100% means the
GPU had work queued, not that it was doing useful work.

**Probe pods that need cluster DNS must set `dnsPolicy: ClusterFirstWithHostNet`.**
A `hostNetwork: true` pod uses the node's resolver by default and cannot resolve
`*.svc.cluster.local`. This produces plausible-looking "under load" readings
that are idle readings, with no error to indicate the failure.
Always confirm reachability (check for HTTP 200) before trusting a load
measurement.

**Implication for GPU observability on AKS: choose NC-series (compute) over
NV-series (visualization) when GPU telemetry matters.** The managed stack
installs and runs correctly on both; the hardware/driver mode determines what
it can report.

**AKS selects the driver branch per SKU family, and the choice is not surfaced
anywhere in the API response beyond the resulting versions.** In one cluster,
`Standard_NC4as_T4_v3` received driver 580.159.04 and CUDA 13.0 (`Tesla T4`),
while `Standard_NV36ads_A10_v5` received 570.211.01 and CUDA 12.8, reported as
`NVIDIA A10-24Q`, a GRID vGPU profile. NC is the compute family, NV the
visualization family, and `gpuProfile.driverType` defaults to system-selected.
A container image pinned to one CUDA version can behave differently across
node pools in the same cluster as a result.

## SKU and region selection

The SKUs, regions, and quota figures below are the defaults for this lab.
Override them for your own subscription and region as described in
[Adapt region and SKU to your subscription](../modules/00-prerequisites.md#adapt-region-and-sku-to-your-subscription)
(Module 0).

A VM size is usable only if it clears **both** gates:

1. The Compute REST API (`Microsoft.Compute/skus`) returns an **empty
   `restrictions` array** for it in that region.
2. `az vm list-usage` shows **non-zero quota** for its family.

Checking only one gate is misleading. As an example, westus3 has reported a
T4 quota of `0/300`, which looks like room for 75 nodes, while the T4 SKU
itself was `NotAvailableForSubscription` in that region: quota that cannot be
spent. `preflight.sh` checks both gates, and calls the Compute REST API
directly for gate 1 instead of `az vm list-skus`: the CLI command filters
client-side and measured 7m23s per call, against about 7 seconds for the REST
call directly.

| SKU | Role | GPU |
|---|---|---|
| `Standard_NC4as_T4_v3` | modules 1–4 (entry GPU pool) | 1× T4 16 GB |
| `Standard_NV36ads_A10_v5` | module 2 (driver comparison) | 1× A10 24 GB |
| `Standard_NC24ads_A100_v4` | module 5 (vLLM inference) | 1× A100 80 GB |

The taint `sku=gpu:NoSchedule` is a **convention from the docs, not an AKS
default**. AKS does not taint GPU nodes automatically. Every GPU pod in this lab
carries the matching toleration; a pod without one stays Pending with no
obvious cause.

## D7: nvidia-fabricmanager is not started on NVSwitch GPU nodes

**Every CUDA workload fails on a managed GPU ND-series node until fabric
manager is started manually.** Verified 2026-09-01 on
`Standard_ND96isrf_H100_v5` (8x H100 SXM GPUs joined by NVSwitch, the switch
fabric that connects NVLink across all GPUs in the node), node pool created
with `--enable-managed-gpu=true`.

The failure does not obviously point to the fabric:

```
RuntimeError: Unexpected error from cudaGetDeviceCount().
Error 802: system not yet initialized
```

CUDA error 802 is `CUDA_ERROR_SYSTEM_NOT_READY`. On the node:

```
nvidia-fabricmanager.service   Loaded: ...; disabled; preset: enabled
                               Active: inactive (dead)
nvidia-smi -q:  Fabric State: In Progress    GPU Fabric GUID: N/A
```

The binary is present at `/usr/bin/nv-fabricmanager`, installed but left
disabled. Starting it resolves the error:

```
systemctl start nvidia-fabricmanager
-> active
-> nvidia-smi -q:  Fabric Status: Success
-> nvidia-smi:     0, NVIDIA H100 80GB HBM3 ...
```

**Why the earlier modules did not hit this.** T4, A10, and A100 in this lab
are PCIe parts with no NVSwitch, so they need no fabric manager. The managed
stack's own checks pass on the ND pool too: the driver installs, the device
plugin advertises 8 GPUs, and DCGM reports metrics, because none of those
checks initialize a CUDA context. As a result, `nvidia.com/gpu: 8` can show as
allocatable on a node where CUDA workloads cannot yet run.

**Workaround.** Start the service on each NVSwitch node before running GPU
work. The setting does not survive node replacement, so a DaemonSet that
enables and starts the service on every matching node is the durable form.
Starting fabric manager is required today for NVSwitch-connected node pools;
the published managed GPU flow does not mention this step.

## A freshly joined GPU node advertises its GPU before it is usable

A node that has just joined the cluster reports `nvidia.com/gpu: 1` as
allocatable, and the scheduler will place a GPU pod on it, before the device
plugin can pass the device into a container. The pod starts and fails:

```
Failed to get device capability: No CUDA GPUs are available.
RuntimeError: No CUDA GPUs are available
```

Observed repeatedly on this lab's cluster, on three separate freshly-created
`NC24ads_A100_v4` nodes. A replica on a settled node ran 7.5 hours unaffected,
which is what distinguishes this from a faulty node: the same manifest works
on a settled node and fails on a new one.

The pod does not recover on its own. `restartPolicy: Always` restarts the same
container against the same stale allocation, so it crashloops. Deleting the pod
so the scheduler makes a fresh placement resolves it:

```bash
kubectl delete pod -n <ns> <pod>
```

This matters for any rollout that coincides with new GPU capacity: scaling a
node pool and deploying onto it in the same step will produce crashlooping
replicas that look like an application fault. Wait for the node to settle, or
delete the affected pods afterwards.

## A GPU node can advertise a GPU it cannot allocate

Observed 2026-09-03 on `Standard_NC24ads_A100_v4`, on one of the freshly
created nodes described above. Every health signal reported the node as fine
while no GPU workload could run on it.

What the cluster reported:

```
capacity:    nvidia.com/gpu: 1
allocatable: nvidia.com/gpu: 1
NPD:         UnhealthyNvidiaDevicePlugin=False  UnhealthyNvidiaDCGMServices=False
             XIDError=False  GPUMissing=False  Ready=True
```

What happened to pods scheduled there:

```
Status: UnexpectedAdmissionError
```

and for containers that did start:

```
Failed to get device capability: No CUDA GPUs are available.
RuntimeError: No CUDA GPUs are available
```

This is the same node-join race described in the previous section, not a
separate hardware fault: the device plugin advertised the GPU to the scheduler
before it could pass the device into a container. Nothing in the node
conditions distinguishes this from a healthy node, so the first symptom is a
workload that does not start.

**Detection.** Node conditions do not catch it, and neither does `nvidia-smi`
alone. `nvidia-smi` queries through NVML; CUDA context creation is a separate
path. On the affected node, `nvidia-smi -L` returned the A100 and its UUID
while every CUDA workload failed with `No CUDA GPUs are available`.

The check that catches it allocates GPU memory:

```bash
python3 -c "import torch; torch.zeros(8, device='cuda'); print('CUDA_OK')"
```

The other reliable signals are the workload's own: `UnexpectedAdmissionError`
on a pod, or a CUDA initialisation error in a container that holds a valid
allocation.

**The host can see the GPU while containers cannot.** On the affected node,
DCGM running as a systemd service returned 57 metrics from `:19400`, so the
driver and the device were working. Only the path that hands the device to a
container was affected, which is why host-level checks such as `nvidia-smi` do
not rule this out.

**Recovery.** Delete the pod:

```bash
kubectl delete pod -n <ns> <pod>
```

The scheduler places a fresh pod, which gets a working allocation, the same
fix as the node-join race above. Reimaging the VMSS instance and replacing the
VM were both tried against this node first and neither fixed it:

```bash
MC=$(az aks show -g <rg> -n <cluster> --query nodeResourceGroup -o tsv)
VMSS=$(az vmss list -g "$MC" --query "[?contains(name,'<pool>')].name" -o tsv)
az vmss reimage -g "$MC" -n "$VMSS" --instance-id <id>
```

This confirms the finding is not a hardware fault: no infrastructure-level
remediation was required, and none resolved it.

## Cluster updates can no-op while reporting success

`az aks update` returns exit code 0 and prints no error when another update is
already in progress on the cluster. The requested change is not applied.

Observed while enabling the managed Gateway API: the command succeeded, but
`ingressProfile.gatewayApi` remained `null` and no CRDs appeared. Re-running the
same command once the cluster was idle produced a request body containing
`"gatewayAPI": {"installation": "Standard"}` and the change took effect.

Two consequences worth building around:

- Serialise cluster updates. Enabling several add-ons in separate commands
  invites this, and node pool operations block cluster updates as well.
- Verify the resulting state rather than the exit code:

```bash
az aks show -g <rg> -n <cluster> \
  --query '{gatewayApi:ingressProfile.gatewayApi, keda:workloadAutoScalerProfile.keda.enabled}'
```

An operation already in flight reports itself:

```
(OperationNotAllowed) Operation is not allowed because there's an in-progress
update managed cluster operation ... on the managed cluster
```

but only when the conflicting command runs while the first is still active. A
command issued after the first completes, against a cluster whose state has not
settled, can still return success without effect.

## Blob CSI mountOptions format for NFS

`best-practices-ml-ops.md` gives a StorageClass whose `mountOptions` each carry a
leading `-o`:

```yaml
mountOptions:
- -o attr_timeout=120
- -o nconnect=4
```

With `parameters.protocol: nfs` this fails. The CSI driver comma-joins
`mountOptions` and passes the result to `mount`, producing:

```
mount -t aznfs -o -o actimeo=120,-o nconnect=4,...
```

and the mount fails with `mount: bad usage`, leaving pods in
`ContainerCreating` with a `FailedMount` event. The `-o` form belongs to
blobfuse, where the options are handed to the blobfuse binary rather than to
`mount`. Other AKS storage articles write them bare.

For `protocol: nfs`, write them without the prefix:

```yaml
mountOptions:
  - nconnect=4
  - noresvport
  - actimeo=120
```

Verified 2026-09-03 on AKS 1.35 with the Blob CSI driver add-on.

## Capacity and quota behaviour on large GPU SKUs

Measured while provisioning 2x `Standard_ND96isrf_H100_v5` in swedencentral,
2026-09-01. This behavior is not described in the published AKS documentation.

**Quota and availability do not imply capacity.** The SKU showed an empty
`restrictions` array and 0/192 family quota; both gates from module 0 passed,
and allocation still failed:

```
AllocationFailed: VM allocation in the Availability Set failed. Allocation for
this Availability Set is constrained (pinned) to a specific cluster, which may
be out of capacity.
```

The request was retried twice with the same result. No API confirms capacity
in advance; the two gates indicate only that the request is allowed, not that
it will succeed.

**The constraint is per node pool.** Each pool's allocation is pinned to one
physical cluster, so a single 2-node pool can fail where two 1-node pools
succeed. If you need N large GPU nodes and one pool will not fill, splitting
across pools is worth trying before assuming the region is empty. Select
workloads on `node.kubernetes.io/instance-type` rather than `agentpool` so pods
land wherever capacity was found.

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
appears to send the stored `gpuProfile` back and the resource provider (RP)
rejects it against the immutability rule, so unrelated mutable properties
cannot be changed either. Workaround: label the node directly with
`kubectl label node`, accepting that it does not survive node replacement.

## Out of scope, and why

**Multi-node NVIDIA RDMA (Remote Direct Memory Access) / InfiniBand.** Not
covered by the modules in this lab. AKS docs contain zero references to
GPUDirect or `nvidia-peermem`, and the only `AKSInfinibandSupport`
documentation is in `use-amd-gpus.md`, which covers AMD MI300X. There is no
published NVIDIA InfiniBand-on-AKS guidance to build on. See
[`modules/09-capstone-multinode.md`](../modules/09-capstone-multinode.md) for
how the capstone documents this limitation.
