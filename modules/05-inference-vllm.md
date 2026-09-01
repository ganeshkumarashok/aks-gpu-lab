# Module 5 — Serve a model with vLLM

A real inference server on a real GPU, and the telemetry to tell whether it is
performing.

```bash
./scripts/20-add-managed-gpu-nodepool.sh a10   # 1x A10, 24 GB
./scripts/50-deploy-vllm.sh
```

First start takes 10–25 minutes: roughly 15 GB of model weights download, then
load into GPU memory.

## Why this model and this SKU

**Qwen2.5-7B-Instruct** is Apache-2.0 and **ungated**. That matters more than it
sounds — a gated model needs a Hugging Face token, and the token dance is the
single most common place a GPU tutorial strands a first-time reader.

**`Standard_NV36ads_A10_v5`** gives one A10 with 24 GB. About 15 GB goes to fp16
weights, leaving room for the KV cache.

> **Known trade-off.** NV-series runs a GRID **vGPU** profile, and on a vGPU the
> DCGM exporter can only report 11 of the 20 fields you saw in module 4 — no
> temperature, no power, and none of the `DCGM_FI_PROF_*` profiling metrics.
> `DCGM_FI_DEV_GPU_UTIL` reads `0` even under load. Memory (`FB_USED`) and vLLM's
> own `:8000/metrics` still work, so the module is fully functional, but if you
> want the full telemetry picture on your inference node, use an NC-series SKU
> such as `Standard_NC24ads_A100_v4` instead. See
> [accuracy notes](../docs/accuracy.md). `--max-model-len=8192` is sized for that
headroom; raising it without lowering `--gpu-memory-utilization` will OOM at
load time, not under load.

## The trap: naming the Service `vllm` breaks vLLM

This one is worth the whole module. If you deploy a `Service` named `vllm`,
Kubernetes injects legacy Docker-link environment variables for it into every
pod in the namespace — including:

```
VLLM_PORT=tcp://10.0.249.17:8000
```

vLLM reads `VLLM_PORT` as **its own** configuration variable, finds a URI where
it expects an integer, and dies:

```
ValueError: VLLM_PORT 'tcp://10.0.249.17:8000' appears to be a URI.
This may be caused by a Kubernetes service discovery issue
```

The cruelty is the timing. It crashes *after* downloading the weights, loading
14.29 GiB onto the GPU, sizing the KV cache, and capturing CUDA graphs — about
90 seconds of apparently perfect progress, then `exitCode: 1` and a crashloop.
Nothing in the failure points at the Service name.

The fix is one line on the pod spec:

```yaml
spec:
  enableServiceLinks: false
```

Renaming the Service to something that does not upper-case into `VLLM_*` also
works. Disabling service links is cleaner, since it removes an entire class of
env-var collision rather than dodging one instance.

This is not vLLM-specific in principle: any server whose config env vars share a
prefix with its own Service name can be broken the same way.

## Three settings that are not obvious

**`/dev/shm` must be enlarged.** vLLM uses shared memory for inter-process
tensor transfer. The Kubernetes default is 64 MB and vLLM crashes on it with an
error that does not mention shared memory. Hence:

```yaml
volumes:
  - name: dshm
    emptyDir:
      medium: Memory
      sizeLimit: 8Gi
```

**The startup probe needs a very high failure threshold.** 180 × 20s = up to an
hour before Kubernetes gives up. A normal 30-second probe kills the pod
repeatedly while it is legitimately downloading weights, producing a crash loop
that looks like a GPU problem and is not.

**`progressDeadlineSeconds` must be raised too.** The default 600s marks the
rollout failed while the download is still running.

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
| high | low | stalled — small batches, or memory-bound decode |
| low | low | idle, or bottlenecked before the GPU (network, tokenization) |
| low | high | short prompts; the GPU is not your constraint |

## Clean up

```bash
./scripts/90-teardown.sh --gpu-only
```

## Next

[Module 6 — Capstone](06-capstone-multinode.md), or stop here — modules 0–5 are
a complete arc on their own.
