# Module 6 — Capstone: multi-node sharded serving on H100

> **Unverified territory.** Modules 0-5 follow published AKS documentation
> end to end. This module does not: as of this writing, multi-node sharded
> serving, GPUDirect RDMA, and InfiniBand for NVIDIA GPUs are not covered by
> any published AKS documentation. See
> [What is and isn't documented](#what-is-and-isnt-documented).

This module is optional. It is also the most expensive and time-consuming
module in the lab (roughly 1-2 hours; see [Cost](#cost)). It provisions two
`Standard_ND96isrf_H100_v5` nodes (8 H100 GPUs each, 16 total) and serves a
single model too large to fit in one node's GPU memory, splitting it across
both nodes: a technique generally called sharding.

## Prerequisites

- Complete modules 0-3 first. This module assumes you can already provision a
  managed GPU node pool and read its DCGM metrics; it does not re-explain
  those steps.
- Quota for an RDMA-enabled H100 (or H200) SKU, in a region where that SKU is
  both available to your subscription and has non-zero quota. This lab's
  scripts default to `Standard_ND96isrf_H100_v5` with 2 nodes in
  `swedencentral`, because that is where the subscription this lab was built
  against holds quota (see `scripts/lib.sh`). Set the environment variables
  `CAP_LOCATION`, `CAP_SKU`, and `CAP_NODE_COUNT` before running the scripts
  below to target a region and SKU where your own subscription has quota.
  `scripts/61-capstone-h100-nodepool.sh` checks availability and quota before
  it provisions anything.
- `helm`, used by `scripts/62-install-kuberay.sh`.

## Why this needs two nodes

`zai-org/GLM-5.2-FP8` is **703.6 GiB** on disk. Each
`Standard_ND96isrf_H100_v5` node has 8 GPUs × 80 GB = **640 GiB** of HBM (High
Bandwidth Memory, the GPU's on-board memory that holds model weights and
activations). The model's weights alone exceed one node's HBM before the KV
cache exists (the KV cache is per-request memory that stores attention keys
and values so the model does not recompute them at every generation step).
Splitting the model across two nodes is required by the hardware.

Verify the model size yourself rather than trusting the number above:

```bash
curl -s https://huggingface.co/api/models/zai-org/GLM-5.2-FP8 \
  | python3 -c '
import json,sys
p=json.load(sys.stdin)["safetensors"]["parameters"]
B={"BF16":2,"F8_E4M3":1,"F32":4}
print(sum(v*B[k] for k,v in p.items())/1024**3, "GiB")'
```

> **Common mistake.** Hugging Face's `safetensors.total` field is a
> **parameter count, not a byte count**. Reading it as a byte count
> understates a bf16 model's size by 2x, which can make a model appear to fit
> on hardware it does not fit on.

The same checkpoint fits on a single H200 node (141 GB/GPU = 1,128 GiB of
HBM). The accelerator generation determines whether this model needs one node
or two.

## Topology: tensor and pipeline parallelism

```bash
--tensor-parallel-size 8    # GPUs per node, over NVLink
--pipeline-parallel-size 2  # nodes, over the network
```

**Tensor parallelism (TP)** splits individual layers across GPUs, so every GPU
in the group computes part of every layer. This requires frequent,
low-latency communication between GPUs, so TP is kept inside a node, where
NVLink (NVIDIA's high-bandwidth GPU-to-GPU interconnect) carries the traffic.

**Pipeline parallelism (PP)** splits the model's layers into consecutive
stages and puts each stage on a different node. Only the activations passed
between stages cross the network, so PP tolerates a network hop between
nodes. TP inside a node and PP across nodes is the standard split for
multi-node serving.

GPU count is not the only constraint. vLLM requires the model's attention
head count to be divisible by the tensor-parallel size, and raises an error
otherwise:

> `Total number of attention heads (N) must be divisible by tensor parallel size (M).`

| Model | Heads | Layers | TP=8 | TP=4 |
|---|---|---|---|---|
| GLM-5.2-FP8 | 64 | 78 | legal (64/8) | legal |
| Qwen2.5-7B-Instruct | 28 | 28 | **illegal** (28 % 8 = 4) | legal (28/4) |

Check a model's head count before provisioning:

```bash
curl -s https://huggingface.co/<model>/resolve/main/config.json \
  | python3 -c 'import json,sys;c=json.load(sys.stdin);print(c["num_attention_heads"],c["num_hidden_layers"])'
```

## What is and isn't documented

| Layer | AKS docs |
|---|---|
| KubeRay, `RayService`, Kueue | Documented: `ray-overview.md`, `deploy-ray-infrastructure.md`, `ray-online-serving.md` |
| Distributed *training* on GPUs | Documented: `ray-train-llm.md`, 4× A100 |
| Multi-node **sharded serving** | Not documented: the Ray series tops out at 1× GPU for `RayService` |
| GPUDirect RDMA, `nvidia-peermem` | Not documented: no references in the AKS docs |
| InfiniBand for NVIDIA | Not documented: `AKSInfinibandSupport` appears only in `use-amd-gpus.md`, for AMD MI300X |

The orchestration layer (KubeRay, `RayService`, Kueue) is documented and
supported. The sharding technique above and RDMA are not. RDMA (Remote Direct
Memory Access) lets a network adapter read and write another machine's memory
directly, without routing through the remote CPU or kernel network stack.
GPUDirect RDMA extends this so a GPU's memory can be accessed the same way,
and InfiniBand is the network fabric this SKU uses to carry that traffic.
Because RDMA and InfiniBand are not documented for this SKU, this module
treats them as something to measure rather than assume.

## Treat RDMA as something to measure

Ray and vLLM shard across nodes over ordinary pod networking. It is slower
than RDMA and it works, so the module can stand on documented ground:

1. Get sharded serving running over standard networking. Measure it.
2. Enable InfiniBand. Measure again.
3. Report the difference.

If step 2 fails, step 1 is still a complete result. This way an undocumented
optimization is validated by measurement rather than assumed to work.

**Checking whether RDMA is in use.** Set `NCCL_DEBUG=INFO` and read the
worker logs. NCCL (NVIDIA Collective Communications Library, used by Ray and
vLLM for cross-GPU communication) announces which transport it selected at
startup:

```bash
kubectl logs -n gpu-lab -l ray.io/group=h100 | grep -E "NET/IB|NET/Socket"
```

`NET/IB : Using ...` means RDMA. `NET/Socket : Using ...` means NCCL fell back
to TCP. This fallback produces no error, so the only way to detect it is to
check the logs.

## Running it

```bash
./scripts/60-capstone-cluster.sh        # swedencentral cluster
./scripts/61-capstone-h100-nodepool.sh  # 2 x ND96isrf_H100_v5
./scripts/62-install-kuberay.sh         # KubeRay operator from MCR
./scripts/63-deploy-rayservice.sh bringup   # cheap mechanism check first
./scripts/63-deploy-rayservice.sh glm       # the real workload
```

These scripts read `CAP_LOCATION`, `CAP_SKU`, and `CAP_NODE_COUNT` from
`scripts/lib.sh` (see [Prerequisites](#prerequisites) to override them for
your own subscription).

Start with `bringup`. It runs Qwen2.5-7B at TP=4/PP=2 across both nodes, a
15 GB download instead of 703 GiB, and proves Ray spans the nodes, the
workers see their GPUs, and cross-node collectives work. This way a topology
problem surfaces before an hour-long download, not after.

## Start fabric manager before deploying anything

`Standard_ND96isrf_H100_v5` has 8 H100 SXM GPUs connected through NVSwitch, an
NVIDIA interconnect chip that lets all 8 GPUs on the node communicate with
each other at full NVLink bandwidth. GPUs connected through NVSwitch (unlike
the PCIe-connected T4, A10, and A100 SKUs used in modules 0-5) depend on a
separate service, `nvidia-fabricmanager`, to configure and initialize that
switch before CUDA can use any GPU on the node. AKS installs
`nvidia-fabricmanager` on this SKU but leaves it **disabled**, so CUDA does
not initialize until the service is started. Every GPU workload fails with:

```
RuntimeError: Unexpected error from cudaGetDeviceCount().
Error 802: system not yet initialized
```

Check and fix it on each H100 node before deploying anything. `kubectl debug
node/<node> ... --profile=sysadmin` starts a privileged pod with the host
filesystem mounted at `/host`, which is what lets `chroot /host` reach the
node's own `systemctl`:

```bash
NODE=$(kubectl get nodes -l node.kubernetes.io/instance-type=Standard_ND96isrf_H100_v5 \
        -o jsonpath='{.items[0].metadata.name}')
kubectl debug node/$NODE -it --image=mcr.microsoft.com/azurelinux/base/core:3.0 \
  --profile=sysadmin -- chroot /host systemctl start nvidia-fabricmanager
```

Confirm it took:

```bash
# Fabric State should read Success, not "In Progress"
nvidia-smi -q | grep -A2 Fabric
```

Every managed-stack check still passes without fabric manager running: the
driver is installed, the device plugin advertises `nvidia.com/gpu: 8`, DCGM
(NVIDIA's Data Center GPU Manager, covered in
[module 4](04-observability.md)) exports metrics, and
[module 3's verification](03-verify.md) steps go green, because none of those
checks initialize a CUDA context. The node reports healthy and schedules GPU
pods that cannot use the GPUs. Modules 0-5 do not hit this because
T4, A10, and A100 are PCIe parts with no NVSwitch, so fabric manager is not
part of their initialization path.

The manual start does not survive node replacement. A DaemonSet that enables
and starts the service is the durable fix.

## Common pitfalls

**Container image.** Neither obvious candidate has both dependencies:
`vllm/vllm-openai` ships vLLM without Ray; the MCR Ray image ships Ray without
vLLM or torch. This module uses `rayproject/ray-llm`, which has both.

**Set `distributed_executor_backend: "ray"` explicitly.** vLLM only
auto-selects Ray under narrow conditions. Otherwise, when world size exceeds
the GPUs on one node, it raises rather than reaching for the cluster.

**One worker replica per physical node.** Without pod anti-affinity, both
replicas can land on the same node, turning a multi-node test into a
single-node test with two pods, with no error to indicate it.

**`enableServiceLinks: false`.** KubeRay names its services
`<name>-head-svc`, so [module 5](05-inference-vllm.md)'s `VLLM_PORT`
collision does not reproduce from KubeRay's own services. Kubernetes still
injects environment variables for every Service in the namespace, though, so
a bare Service named `vllm` in the same namespace causes the same collision
in these pods.

**Provisioning can fail even when both preflight gates pass.** Both
[module 0](00-prerequisites.md) gates can pass (empty `restrictions`,
non-zero quota) and node pool creation can still fail with:

```
AllocationFailed: allocation for this Availability Set is constrained (pinned)
to a specific cluster, which may be out of capacity
```

This is a capacity signal, not a configuration error. Three things follow:

- **The pin is per node pool.** Two 1-node pools can succeed where one
  2-node pool fails. That is why the manifests select on
  `node.kubernetes.io/instance-type` rather than `agentpool`: workers land in
  whichever pool got capacity.
- **Quota is charged against desired count.** A pool stuck at `count: 2` with
  one live node still reserves both nodes' vCPU, and the next pool fails with
  `InsufficientVCPUQuota: remaining 0`. Scale the stalled pool down to its
  real size to release the reserved quota.
- **`az aks nodepool update` does not work on a managed GPU pool.** Even
  `--labels` is rejected with `PropertyChangeNotAllowed` on
  `gpuProfile.nvidia.managementMode`, a field the command does not touch. Use
  `kubectl label node` instead.

## Cost

This is the most expensive module in the lab by a wide margin: 2 nodes of
`Standard_ND96isrf_H100_v5` (16 H100 GPUs total) for 1-2 hours. In the
subscription this lab was built against, two nodes is the entire
`standardNDSFH100v5Family` quota, leaving no capacity to run a second attempt
while the first is up. Check your own quota with `az vm list-usage --location
<region>` before you start (see [Prerequisites](#prerequisites) to adapt the
region and SKU). Treat a run as a budgeted session: plan it, run it, capture
the results, then tear it down.

```bash
./scripts/90-teardown.sh --capstone-gpu-only   # release the H100s, keep the cluster
./scripts/90-teardown.sh --capstone            # delete everything
```
