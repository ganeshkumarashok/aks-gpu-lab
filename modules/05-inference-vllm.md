# Module 5 — Serve a model with vLLM

vLLM is an open-source inference server for large language models. It accepts
an OpenAI-compatible HTTP API, batches concurrent requests, and manages the GPU
memory each request needs for generation. This module deploys vLLM on a single
GPU and uses the metrics from module 4 to check whether it is actually using
the hardware.

This module builds on the managed GPU node pool from module 2 and the metrics
introduced in module 4.

```bash
./scripts/20-add-managed-gpu-nodepool.sh a100  # 1x A100, 80 GB
./scripts/50-deploy-vllm.sh
```

`20-add-managed-gpu-nodepool.sh a100` creates the `a100np` node pool if it does
not already exist. `50-deploy-vllm.sh` applies `manifests/vllm-a100.yaml`,
which creates the `gpu-lab` namespace used by every command below.

First start takes 10–25 minutes: roughly 15 GB of model weights download, then
load into GPU memory.

### Region and SKU

The region and SKU come from `scripts/lib.sh`: `LAB_LOCATION` (default
`westus2`) and `LAB_SKU_A100` (default `Standard_NC24ads_A100_v4`). Both are
overridable by environment variable. If your subscription does not have A100
quota in `westus2`, export `LAB_LOCATION` and `LAB_SKU_A100` for a region and
SKU where it does, then re-run `./scripts/preflight.sh` to confirm the SKU
clears both the availability and quota gates there (see
[Module 0](00-prerequisites.md)) before starting this module.

## Why this model and this SKU

Qwen2.5-7B-Instruct is licensed Apache-2.0 and ungated, so downloading it needs
no Hugging Face access token. A gated model requires one, which is a common
place for a first-time reader to get stuck.

`Standard_NC24ads_A100_v4` provides one NVIDIA A100 GPU with 80 GB of memory.
Loading the model in bf16 uses about 15 GB, leaving most of the card for the
KV cache: the GPU memory vLLM reserves to hold the attention keys and values
for tokens already generated in a request. KV-cache size grows with sequence
length and the number of concurrent requests, and it is usually the resource
that runs out first during serving. The headroom on this SKU is why this
module runs `--max-model-len=16384`; a 24 GB card would need a much lower
limit, closer to 8192.

> **Why not the cheaper A10?** `Standard_NV36ads_A10_v5` is an NV-series SKU
> that runs a GRID vGPU (virtual GPU) profile (`NVIDIA A10-24Q`). On this vGPU
> profile, the DCGM (NVIDIA Data Center GPU Manager) exporter reports only
> **11** metric fields instead of 23: no temperature, no power, and none of
> the `DCGM_FI_PROF_*` profiling counters. Whether the fields it does report
> reflect meaningful values under load is unvalidated on vGPU. The missing
> field count alone removes most of the observability approach introduced in
> module 4, so this module uses the A100 instead. See
> [accuracy notes](../docs/accuracy.md).

Raising `--max-model-len` without lowering `--gpu-memory-utilization` causes an
out-of-memory error at load time, not under load.

## Four settings that are not obvious

**`/dev/shm` must be enlarged.** `/dev/shm` is the shared-memory tmpfs that
Linux processes use to exchange data without copying it. vLLM uses it for
inter-process tensor transfer. The Kubernetes container default is 64 MB, and
vLLM fails against that limit with an error that does not mention shared
memory. Set a larger size explicitly:

```yaml
volumes:
  - name: dshm
    emptyDir:
      medium: Memory
      sizeLimit: 8Gi
```

**The startup probe needs a high failure threshold.** 180 × 20s allows up to
an hour before Kubernetes gives up. A normal 30-second probe kills the pod
repeatedly while it is still downloading weights, producing a crash loop that
resembles a GPU problem but is not one.

**`progressDeadlineSeconds` must be raised too.** The default 600s marks the
rollout failed while the download is still running.

**`enableServiceLinks: false` avoids an environment-variable collision.**
Kubernetes injects legacy Docker-link variables for every Service in the
namespace into every pod. A Service named `vllm` produces `VLLM_PORT`, which
vLLM reads as its own configuration and rejects because it holds a URI rather
than a port number. The pod fails after the model has finished loading, and
the error does not mention the Service. Disabling service links removes the
whole class of collision for any server whose configuration variables share a
prefix with its Service name:

```yaml
spec:
  enableServiceLinks: false
```

## Verify it works

```bash
kubectl run vllm-curl -n gpu-lab --rm -i --restart=Never \
  --image=mcr.microsoft.com/azurelinux/base/core:3.0 -- \
  curl -s http://vllm:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"Qwen/Qwen2.5-7B-Instruct",
         "messages":[{"role":"user","content":"Reply with exactly: GPU lab online."}],
         "max_tokens":16,"temperature":0}'
```

## Now watch both metric sources

With traffic flowing, compare the two:

```bash
# GPU side
curl -s http://localhost:19400/metrics | grep -E 'GPU_UTIL|FB_USED'
# Server side
curl -s http://vllm:8000/metrics | grep -E 'vllm:(num_requests|time_to_first_token)'
```

The interesting states are the mismatches:

| GPU util | Server throughput | Meaning |
|---|---|---|
| high | high | working as intended |
| high | low | stalled: small batches, or memory-bound decode |
| low | low | idle, or bottlenecked before the GPU (network, tokenization) |
| low | high | short prompts; the GPU is not the constraint |

## Clean up

GPU nodes are the cost of this lab. Run this once you are done, or see the
[repository README](../README.md#cost) for overall cost and full teardown
options.

```bash
./scripts/90-teardown.sh --gpu-only
```

## Next

[Module 6 — Capstone](06-capstone-multinode.md), or stop here: modules 0–5 are
a complete arc on their own.
