# GPU on AKS — an end-to-end lab

A runnable walkthrough of the **fully managed GPU experience** on Azure
Kubernetes Service: from an empty subscription to a GPU node pool that installs
and maintains its own NVIDIA stack, to a live LLM inference server, with real
telemetry at every step.

Every command traces to published AKS documentation. Where the docs are
currently wrong, this lab uses the correct value and records the discrepancy in
[`docs/accuracy.md`](docs/accuracy.md).

> **Preview.** The managed GPU experience is in preview. The field behind it,
> `gpuProfile.nvidia.managementMode`, exists only on preview API versions, so the
> `aks-preview` CLI extension is required. See
> [`docs/accuracy.md`](docs/accuracy.md#why-this-lab-is-on-the-preview-surface).

## What makes this different

Most GPU-on-Kubernetes tutorials spend their first third making you install a
driver, a device plugin, and a metrics exporter. This one doesn't — that's the
point of the managed experience. One flag,

```bash
az aks nodepool add ... --enable-managed-gpu=true
```

and AKS installs and maintains **three** things for you:

| Component | What it gives you |
|---|---|
| NVIDIA GPU driver | containers can talk to the hardware |
| NVIDIA device plugin | `nvidia.com/gpu` becomes schedulable |
| DCGM + dcgm-exporter | GPU metrics on port `19400` |

So the interesting content — *is my GPU actually being used, and how would I
know?* — starts at minute five instead of minute fifty.

## Modules

| # | Module | What you do | Time |
|---|---|---|---|
| 0 | [Prerequisites](modules/00-prerequisites.md) | Versions, feature flag, quota. Zero cost. | 5 min |
| 1 | [Cluster](modules/01-cluster.md) | AKS cluster + CPU system pool | 10 min |
| 2 | [Managed GPU node pool](modules/02-managed-gpu-nodepool.md) | The one flag that installs the stack | 10 min |
| 3 | [Verify the stack](modules/03-verify.md) | Prove all three components landed | 5 min |
| 4 | [Runtime telemetry](modules/04-observability.md) | DCGM metrics, NPD health, what to watch | 15 min |
| 5 | [Serve a model](modules/05-inference-vllm.md) | vLLM on one A100, real inference | 30 min |
| 6 | [Capstone (optional)](modules/06-capstone-multinode.md) | Multi-node sharded serving on H100 | 1-2 h |

Modules 0–5 run in **westus2**. The capstone runs in **swedencentral** on a
separate cluster — that split is forced by GPU quota, not by design.

## Quick start

```bash
./scripts/preflight.sh                          # read-only; costs nothing
./scripts/10-create-cluster.sh
./scripts/20-add-managed-gpu-nodepool.sh t4
./scripts/30-verify-managed-stack.sh t4
```

Then for the inference module:

```bash
./scripts/20-add-managed-gpu-nodepool.sh a100
./scripts/50-deploy-vllm.sh
```

## Cost

GPU nodes are the entire cost of this lab. **Run teardown when you stop.**

```bash
./scripts/90-teardown.sh --gpu-only   # drop GPU pools, keep the cluster
./scripts/90-teardown.sh              # delete everything
```

The T4 modules are cheap enough to repeat freely. The A100 inference module is
several times that. The capstone is far more expensive than the rest combined
and is deliberately opt-in.

## Validation status

This lab was executed against a real subscription, not just authored. What has
actually been run, and what has not:

| Module | Status | Evidence |
|---|---|---|
| 0 Prerequisites | **Verified** | preflight exits 0; az 2.90.0, aks-preview 19.0.0b29, feature Registered |
| 1 Cluster | **Verified** | cluster created in westus2, k8s 1.35.7, 2 system nodes Ready |
| 2 Managed GPU node pool | **Verified** | `gpuProfile` returned `driver=Install, managementMode=Managed` on T4, A10 and A100 pools |
| 3 Verify the stack | **Verified** | 5 of 6 checks PASS; check 4 WARNs by design (see D6) |
| 4 Runtime telemetry | **Verified** | DCGM live on `:19400`; field sets measured across A10 vGPU (11), T4 (20), A100 (23), H100 (24) |
| 5 Serve a model | **Verified** | vLLM v0.28.0 on A100 served `'GPU lab online.'`; 12334 tokens generated under a 12-request load |
| 6 Capstone | **Partially verified** | cluster, H100 pool (`gpus=8`, `dcgm=enabled`), and KubeRay 1.6.1 all verified live in swedencentral. Cross-node sharding **not** verified — a second H100 would not allocate (`AllocationFailed`, capacity) |

Anything marked *not verified* should be treated as untested, because it is.

## Layout

```
scripts/     numbered, idempotent, safe to re-run
manifests/   Kubernetes YAML applied by the scripts
modules/     the written walkthrough, one file per module
docs/        accuracy notes, citations, known doc defects
```

Configuration lives in `scripts/lib.sh` and is overridable by environment
variable — `LAB_LOCATION`, `LAB_RG`, `LAB_CLUSTER`, and the SKU names.
