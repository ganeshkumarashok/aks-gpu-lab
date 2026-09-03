# Module 6: The inference service

Two vLLM replicas, each on its own GPU node, sharing the model volume from
module 5, behind a Service.

```bash
kubectl apply -f manifests/vllm-serving.yaml
kubectl rollout status deployment/vllm -n inference --timeout=1800s
```

## Why this model and this SKU

**Qwen2.5-7B-Instruct** is Apache-2.0 and ungated. A gated model needs a Hugging
Face token, which is the most common place a first run stalls.

**`Standard_NC24ads_A100_v4`** provides one A100 with 80 GB. NC-series is the
compute family and receives the datacenter driver, so DCGM reports the full
metric set. NV-series runs a GRID vGPU profile that publishes 11 of the 23
fields, omitting power, temperature, and every `DCGM_FI_PROF_*` counter, which
would leave module 4 with nothing to read.

## Settings that are not obvious

**Weights come from the shared volume.** `HF_HUB_OFFLINE=1` makes a missing file
fail immediately rather than start a multi-gigabyte download inside
a serving pod.

**`/dev/shm` must be enlarged.** vLLM uses shared memory for inter-process
tensor transfer. The container default is 64 MB, and the resulting failure does
not mention shared memory.

**Startup, readiness, and liveness probes use different thresholds.** Model
load takes minutes. The startup probe allows 120 × 10s (up to 20 minutes)
before the container is considered failed. The readiness probe fails after a
5s period × 3 failures (about 15 seconds) with no response. The liveness
probe is slower: a 30s period × 6 failures (about 3 minutes), because a
liveness probe that fires during a long generation restarts a replica that is
working correctly.

**`enableServiceLinks: false`.** The Service is named `vllm`, so Kubernetes
would inject `VLLM_PORT` into every pod in the namespace. vLLM reads that as its
own configuration, finds a URI where it expects a port, and exits after the
model has finished loading.

## Settings that make this production-shaped

| Setting | Without it |
|---|---|
| `topologySpreadConstraints` | both replicas can land on one node, so the replica count buys nothing |
| `PodDisruptionBudget: minAvailable: 1` | a node drain can remove every replica at once |
| `maxSurge: 0` | a rollout requests a GPU that does not exist and stalls |
| `preStop` sleep + 120s grace | in-flight generations are cut off during a rollout |
| `readOnly: true` on the volume | a replica can corrupt weights other replicas are reading |

`maxSurge: 0` is specific to constrained hardware. The Kubernetes default of
25% surge assumes a spare node is available. With GPUs, it usually is not, so a
rollout requests capacity that cannot be scheduled and stops partway.

## Verify

Both replicas ready, on different nodes:

```bash
kubectl get pods -n inference -l app.kubernetes.io/name=vllm -o wide
```

Confirm the model loaded from the volume rather than downloading:

```bash
kubectl logs -n inference -l app.kubernetes.io/name=vllm --tail=50 | grep -iE "loading|weights|took"
```

Send a request:

```bash
kubectl run -n inference vllm-check --rm -i --restart=Never \
  --image=mcr.microsoft.com/azurelinux/base/core:3.0 -- \
  curl -s http://vllm:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"qwen","messages":[{"role":"user","content":"Reply with exactly: service online."}],"max_tokens":16,"temperature":0}'
```

## Observed during a real node removal

Scaling the node pool down exercises the whole arrangement at once. What happened
on this cluster when a node was removed while the service was serving:

```
node-2   Ready,SchedulingDisabled          <- AKS cordons the node it will remove
vllm-2v5kd   1/1  Terminating   node-2     <- its replica drains
vllm-6zmgj   0/1  Running       node-1     <- a replacement starts elsewhere
vllm-l5jtc   1/1  Running       node-0     <- this one keeps serving throughout

PDB vllm   MIN AVAILABLE 1   ALLOWED DISRUPTIONS 0
```

The disruption budget dropping to zero allowed disruptions is the mechanism
working, not a fault: with one replica still starting, no further voluntary
disruption is permitted until it is ready.

The cost of losing a node is reduced capacity for the few minutes a replacement
takes to load, rather than an outage.

## Test that the availability is real

A replica count only helps if losing one replica is survivable. Delete one and
watch whether the service keeps answering:

```bash
kubectl delete pod -n inference -l app.kubernetes.io/name=vllm --field-selector status.phase=Running \
  --wait=false $(kubectl get pods -n inference -l app.kubernetes.io/name=vllm -o name | head -1)
```

Requests through the Service should continue to be served by the surviving
replica. The deleted replica returns after its model load, which is the cost of
losing one: reduced capacity for minutes, not an outage.

## Next

[Module 7: Ingress and routing](07-gateway.md)
