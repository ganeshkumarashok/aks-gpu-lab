# Module 6 — Capstone: multi-node sharded serving on H100

> **Read this first.** Modules 0–5 stand entirely on published AKS
> documentation. This one does not, and it is labelled that way deliberately.
> See [What is and isn't documented](#what-is-and-isnt-documented).

Two `Standard_ND96isrf_H100_v5` nodes, 16 H100s, one model too large to fit on
either node alone.

## Why two nodes is required, not staged

`zai-org/GLM-5.2-FP8` is **703.6 GiB** on disk. One node has 8 × 80 GB = **640
GiB** of HBM. The weights exceed a single node before any KV cache exists, so
the split is forced by hardware.

Verify it yourself rather than trusting the number:

```bash
curl -s https://huggingface.co/api/models/zai-org/GLM-5.2-FP8 \
  | python3 -c '
import json,sys
p=json.load(sys.stdin)["safetensors"]["parameters"]
B={"BF16":2,"F8_E4M3":1,"F32":4}
print(sum(v*B[k] for k,v in p.items())/1024**3, "GiB")'
```

> **A trap worth internalising.** Hugging Face's `safetensors.total` is a
> **parameter count, not a byte count**. Reading it as bytes understates a bf16
> model by exactly 2×, which is enough to convince you a model fits on hardware
> it cannot fit on.

The same checkpoint fits on **one** H200 node (141 GB/GPU = 1,128 GiB). That
contrast — identical model, identical config, one node versus two — is the point
of the module.

## Topology, and the constraint that actually decides it

```
--tensor-parallel-size 8    # GPUs per node, over NVLink
--pipeline-parallel-size 2  # nodes, over the network
```

Tensor parallelism is chatty and belongs inside a node where NVLink carries it.
Pipeline parallelism passes activations between stages and tolerates a network
hop. That is the standard split.

But GPU count is not what constrains you. **vLLM requires the model's attention
head count to be divisible by the tensor-parallel size**, and raises otherwise:

> `Total number of attention heads (N) must be divisible by tensor parallel size (M).`

| Model | Heads | Layers | TP=8 | TP=4 |
|---|---|---|---|---|
| GLM-5.2-FP8 | 64 | 78 | legal (64/8) | legal |
| Qwen2.5-7B-Instruct | 28 | 28 | **illegal** (28 % 8 = 4) | legal (28/4) |

Check before you provision:

```bash
curl -s https://huggingface.co/<model>/resolve/main/config.json \
  | python3 -c 'import json,sys;c=json.load(sys.stdin);print(c["num_attention_heads"],c["num_hidden_layers"])'
```

## What is and isn't documented

| Layer | AKS docs |
|---|---|
| KubeRay, `RayService`, Kueue | **documented** — `ray-overview.md`, `deploy-ray-infrastructure.md`, `ray-online-serving.md` |
| Distributed *training* on GPUs | **documented** — `ray-train-llm.md`, 4× A100 |
| Multi-node **sharded serving** | **not documented** — the Ray series tops out at 1× GPU for `RayService` |
| GPUDirect RDMA, `nvidia-peermem` | **not documented** — zero references anywhere in the AKS docs |
| InfiniBand for NVIDIA | **not documented** — `AKSInfinibandSupport` appears only in `use-amd-gpus.md`, for AMD MI300X |

The orchestration layer is supported. The sharding and RDMA layers are not. That
shapes how this module treats RDMA.

## RDMA is a measurement, not a prerequisite

Ray and vLLM will shard across nodes over ordinary pod networking. It is slower
than RDMA and it works, which means the module can stand on documented ground:

1. Get sharded serving running over standard networking. Measure it.
2. Enable InfiniBand. Measure again.
3. Report the difference.

If step 2 fails, step 1 is still a complete result. An undocumented optimisation
becomes an experiment with a number attached instead of a configuration step
asserted without a citation.

**Proving RDMA is actually in use** — set `NCCL_DEBUG=INFO` and read the worker
logs. NCCL announces its transport:

```bash
kubectl logs -n gpu-lab -l ray.io/group=h100 | grep -E "NET/IB|NET/Socket"
```

`NET/IB : Using ...` means RDMA. `NET/Socket : Using ...` means it fell back to
TCP silently — which looks like nothing at all unless you check.

## Running it

```bash
./scripts/60-capstone-cluster.sh        # swedencentral cluster
./scripts/61-capstone-h100-nodepool.sh  # 2 x ND96isrf_H100_v5
./scripts/62-install-kuberay.sh         # KubeRay operator from MCR
./scripts/63-deploy-rayservice.sh bringup   # cheap mechanism check first
./scripts/63-deploy-rayservice.sh glm       # the real workload
```

Start with `bringup`. It runs Qwen2.5-7B at TP=4/PP=2 across both nodes — a
15 GB download instead of 703 GiB — and proves Ray spans the nodes, the workers
see their GPUs, and cross-node collectives work. Debugging a topology problem
after an hour of downloading is a bad way to spend an hour.

## Things that will bite you

**The images.** Neither obvious candidate has both dependencies:
`vllm/vllm-openai` ships vLLM without Ray; the MCR Ray image ships Ray without
vLLM or torch. This module uses `rayproject/ray-llm`, which has both.

**Set `distributed_executor_backend: "ray"` explicitly.** vLLM only auto-selects
Ray under narrow conditions. Otherwise, when world size exceeds the GPUs on one
node, it raises rather than reaching for the cluster.

**One worker replica per physical node.** Without pod anti-affinity both replicas
can land on the same node, and a multi-node test quietly becomes a single-node
test with two pods.

**`enableServiceLinks: false`.** KubeRay names its services `<name>-head-svc`,
so module 5's `VLLM_PORT` collision does not reproduce from KubeRay itself. But
Kubernetes injects env vars for *every* service in the namespace — so a bare
Service named `vllm` in the same namespace still poisons these pods.

**Provisioning can fail for reasons that are not your fault, and it did here.**
Both module 0 gates passed — empty `restrictions`, 0/192 quota — and allocation
still failed twice:

```
AllocationFailed: allocation for this Availability Set is constrained (pinned)
to a specific cluster, which may be out of capacity
```

Three things follow, all learned the hard way:

- **The pin is per node pool.** Two 1-node pools can succeed where one 2-node
  pool fails. That is why the manifests select on
  `node.kubernetes.io/instance-type` rather than `agentpool` — workers land in
  whichever pool actually got capacity.
- **Quota is charged against desired count.** A pool stuck at `count: 2` with one
  live node still reserves both nodes' vCPU, and the next pool fails with
  `InsufficientVCPUQuota: remaining 0`. Scale the stalled pool down to its real
  size to release it.
- **`az aks nodepool update` does not work on a managed GPU pool.** Even
  `--labels` is rejected with `PropertyChangeNotAllowed` on
  `gpuProfile.nvidia.managementMode`, a field you never touched. Use
  `kubectl label node` instead.

## Cost

This is the most expensive thing in the repo by a wide margin, and two nodes is
the entire `standardNDSFH100v5Family` quota in the target subscription — there
is no capacity to run a second attempt while the first is up. Treat a run as a
budgeted session: plan it, run it, capture the numbers, tear it down.

```bash
./scripts/90-teardown.sh --capstone-gpu-only   # release the H100s, keep the cluster
./scripts/90-teardown.sh --capstone            # delete everything
```
