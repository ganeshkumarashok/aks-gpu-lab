# GPU on AKS: an end-to-end lab

A runnable walkthrough of the **fully managed GPU experience** on Azure
Kubernetes Service: from an empty subscription to a GPU node pool that installs
and maintains its own NVIDIA stack, to a live LLM inference server, with real
telemetry at every step.

Every command traces to published AKS documentation. Citations, version
floors, and any values that differ from what is currently published are
recorded in [`docs/accuracy.md`](docs/accuracy.md).

> **Preview.** The managed GPU experience is in preview. The field behind it,
> `gpuProfile.nvidia.managementMode`, exists only on preview API versions, so the
> `aks-preview` CLI extension is required. See
> [`docs/accuracy.md`](docs/accuracy.md#why-this-lab-is-on-the-preview-surface).

## Prerequisites

You need:

- An Azure subscription, with `az login` completed and permission to create
  AKS clusters and GPU node pools.
- Azure CLI ≥ 2.85.0 and the `aks-preview` extension ≥ 19.0.0b29.
- `kubectl` (install with `az aks install-cli` if you do not have it).
- GPU quota for the NVIDIA GPU SKUs this lab uses: T4, A10, and A100 for
  modules 0-5, H100 for the capstone.

Run [Module 0 — Prerequisites](modules/00-prerequisites.md) first. It checks
all of the above automatically and reports exactly what is missing, at zero
cost.

## Managed GPU stack

Creating a GPU node pool with the managed GPU experience enabled:

```bash
az aks nodepool add ... --enable-managed-gpu=true
```

AKS installs and maintains three components on every node in the pool:

| Component | What it gives you |
|---|---|
| NVIDIA GPU driver | containers can talk to the hardware |
| NVIDIA device plugin | `nvidia.com/gpu` becomes schedulable |
| DCGM + dcgm-exporter | GPU metrics on port `19400` |

DCGM (NVIDIA Data Center GPU Manager) is NVIDIA's GPU monitoring daemon;
`dcgm-exporter` publishes its metrics in Prometheus format. Module 3 confirms
all three components landed, and module 4 covers how to read the metrics.

## Modules

| # | Module | What you do | Time |
|---|---|---|---|
| 0 | [Prerequisites](modules/00-prerequisites.md) | Versions, feature flag, quota. Zero cost. | 5 min |
| 1 | [Cluster](modules/01-cluster.md) | AKS cluster + CPU system pool | 10 min |
| 2 | [Managed GPU node pool](modules/02-managed-gpu-nodepool.md) | The one flag that installs the stack | 10 min |
| 3 | [Verify the stack](modules/03-verify.md) | Prove all three components landed | 5 min |
| 4 | [Runtime telemetry](modules/04-observability.md) | DCGM metrics, NPD (Node Problem Detector) health, what to watch | 15 min |
| 5 | [Serve a model](modules/05-inference-vllm.md) | vLLM on one A100, real inference | 30 min |
| 6 | [Capstone (optional)](modules/06-capstone-multinode.md) | Multi-node sharded serving on H100 | 1-2 h |

Modules 0–5 run in **westus2**. The capstone runs in **swedencentral** on a
separate cluster, because the H100 SKU it needs has quota there and not in
westus2. These regions and SKUs reflect where this lab's authoring
subscription had availability and quota, not a requirement of the lab itself.

To use your own subscription's region and SKUs instead, set the corresponding
environment variables before running the scripts, or edit the defaults in
[`scripts/lib.sh`](scripts/lib.sh): `LAB_LOCATION`, `LAB_SKU_T4`,
`LAB_SKU_A10`, `LAB_SKU_A100` for modules 0-5, and `CAP_LOCATION`, `CAP_SKU`
for the capstone. [Module 0](modules/00-prerequisites.md#the-two-gate-rule)
covers how to confirm a SKU is both available and has quota in a given region.

## Quick start

Runs modules 0-3: creates the cluster and a T4 GPU node pool, and verifies the
managed stack.

```bash
./scripts/preflight.sh                          # read-only; costs nothing
./scripts/10-create-cluster.sh
./scripts/20-add-managed-gpu-nodepool.sh t4
./scripts/30-verify-managed-stack.sh t4
```

Then for the inference module, adds an A100 node pool and deploys vLLM:

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
several times that. The capstone costs far more than the rest of the lab
combined and is opt-in.

## Validation status

Every module's commands have been run against a live Azure subscription. The
table records the result for each module, including what remains unverified.

| Module | Status | Evidence |
|---|---|---|
| 0 Prerequisites | **Verified** | preflight exits 0; az 2.90.0, aks-preview 19.0.0b29, feature Registered |
| 1 Cluster | **Verified** | cluster created in westus2, k8s 1.35.7, 2 system nodes Ready |
| 2 Managed GPU node pool | **Verified** | `gpuProfile` returned `driver=Install, managementMode=Managed` on T4, A10 and A100 pools |
| 3 Verify the stack | **Verified** | 5 of 6 checks PASS; check 4 WARNs by design (see D6) |
| 4 Runtime telemetry | **Verified** | DCGM live on `:19400`; field sets measured across A10 vGPU (11), T4 (20), A100 (23), H100 (24) |
| 5 Serve a model | **Verified** | vLLM v0.28.0 on A100 served `'GPU lab online.'`; 12334 tokens generated under a 12-request load |
| 6 Capstone | **Partially verified** | End-to-end on **one** H100 node: managed GPU stack, KubeRay 1.6.1, RayService + Ray Serve LLM, vLLM via Ray placement groups, real inference returned. Required starting `nvidia-fabricmanager` by hand first (see D7). **Cross-node sharding (PP=2) and NCCL-over-InfiniBand NOT verified**: a second H100 would not allocate (`AllocationFailed`, capacity) |

Treat anything marked **not verified** as untested.

## Layout

```
scripts/     numbered, idempotent, safe to re-run
manifests/   Kubernetes YAML applied by the scripts
modules/     the written walkthrough, one file per module
docs/        accuracy notes, citations, known doc defects
```

Configuration lives in `scripts/lib.sh` and is overridable by environment
variable: `LAB_LOCATION`, `LAB_RG`, `LAB_CLUSTER`, and the SKU names.
