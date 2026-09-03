# Module 8: Scaling, and what it cannot fix

Autoscaling an LLM service is less useful than it looks, and the reasons are
worth understanding before wiring anything up.

## Model load time sets the floor

A new replica is not useful when the pod is scheduled. It is useful when the
model is resident in GPU memory. From a mounted volume that is tens of seconds
to minutes; from a download it is longer.

Reactive autoscaling responds to load that has already arrived. If the response
takes two minutes, the burst is over or the queue is deep before the new replica
serves anything. This is why production inference stacks tend to run a planned
replica count with a router that uses the capacity well, rather than chasing
demand.

## GPU utilisation is the wrong signal

The obvious metric is the misleading one. Measured on an A100 in this lab,
serving Qwen2.5-7B under twelve concurrent requests:

| Metric | Idle | Under load |
|---|---|---|
| `DCGM_FI_DEV_GPU_UTIL` | 0 | 100 |
| `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE` | 0.000 | 0.097 |

`GPU_UTIL` counts time where any kernel was resident, not useful work. Decode is
memory-bandwidth-bound, so it reads near 100% across a wide range of real load.
As a scaling input it saturates almost immediately and stops carrying
information.

## Signals that track load

vLLM publishes the queue state directly on `:8000/metrics`:

| Metric | Meaning |
|---|---|
| `vllm:num_requests_waiting` | requests queued and not yet started. The clearest overload signal |
| `vllm:num_requests_running` | requests currently being generated |
| `vllm:gpu_cache_usage_perc` | KV cache occupancy. Approaching 1.0 means requests will start queueing |
| `vllm:time_to_first_token_seconds` | user-visible latency, and what an SLO is usually written against |

Scale on `num_requests_waiting`, or on the ratio of waiting to running. Both
respond to load rather than to the shape of the workload.

## If you do autoscale

AKS documents KEDA with Azure Managed Prometheus
([Autoscale GPU workloads with KEDA](https://learn.microsoft.com/azure/aks/autoscale-gpu-workloads-with-keda)).
That article's example scales on `DCGM_FI_DEV_GPU_UTIL`, which is a reasonable
signal for training or batch work and a poor one here, for the reason above.
The same mechanism works with a vLLM queue metric:

```yaml
triggers:
  - type: prometheus
    metadata:
      serverAddress: <managed-prometheus-query-endpoint>
      metricName: vllm_num_requests_waiting
      query: sum(vllm:num_requests_waiting{namespace="inference"})
      threshold: '5'
    authenticationRef:
      name: azure-managed-prometheus-trigger-auth
```

Two constraints apply on this cluster:

- **Scaling pods is not scaling GPUs.** KEDA adds replicas; a replica needs a
  free GPU. Without a node to place it on, the pod stays `Pending`.
- **Managed GPU node pools do not support the cluster autoscaler during
  preview.** Node capacity is changed with `az aks nodepool scale`. Pod
  autoscaling above a fixed node count only redistributes what already exists.

## What to do instead

For a fixed GPU budget, the useful work is in serving the capacity well rather
than adding to it:

| Lever | Effect |
|---|---|
| `--max-num-seqs` | batch size ceiling. Larger raises throughput and per-request latency |
| `--gpu-memory-utilization` | more KV cache, so more concurrent sequences before queueing |
| `--max-model-len` | shorter contexts leave room for more concurrent requests |
| Prefix caching | shared prompt prefixes skip prefill entirely |
| Model-aware routing | send a request to the replica that already holds its prefix |

The last one is where the gateway's limits in module 7 start to matter. Plain
load balancing spreads requests evenly, which is the wrong thing to do when one
replica already holds the KV cache for a conversation. That is the gap the
[Gateway API Inference Extension](https://gateway-api-inference-extension.sigs.k8s.io/)
and [llm-d](https://llm-d.ai) address. Neither is documented for AKS, and
neither is deployed here.

## A crashlooping pod still holds its GPU

A pod in `CrashLoopBackOff` keeps its resource reservation. The GPU stays
allocated to a container that is not doing anything with it, and the next pod
that needs one sits `Pending` with:

```
0/4 nodes are available: 2 Insufficient nvidia.com/gpu
```

while `kubectl get nodes` still reports the GPU as allocatable. The two are not
in conflict: allocatable is capacity, and the scheduler is reporting what is
left after existing reservations.

To find the holder, look across all namespaces rather than the one you are
working in:

```bash
kubectl get pods -A -o wide --field-selector spec.nodeName=<node>
kubectl describe node <node> | grep -A12 'Allocated resources'
```

The `Allocated resources` table is the authority. It shows `nvidia.com/gpu 1 1`
on a node whose GPU appears free from the outside.

This matters most after a failed rollout or an abandoned experiment: scarce GPU
capacity stays pinned by a workload nobody is watching.

**Cordon does not evict.** `kubectl cordon` stops *new* pods being scheduled to a
node; pods already running there stay, including one that is crashlooping. After
cordoning an unhealthy GPU node, delete the pod so the scheduler places it
elsewhere, or it keeps restarting on the node you just took out of service.

**Freeing the GPU is not always enough.** A pod that was already `Pending` can
bind to the released GPU before the device plugin has finished reclaiming it,
and then start with no device visible:

```
Failed to get device capability: No CUDA GPUs are available
RuntimeError: Engine core initialization failed
```

The pod holds a valid allocation and the container sees nothing. Deleting the
pod so the scheduler places a fresh one resolves it. Worth recognising, because
the message points at CUDA rather than at the race that caused it.

## Verify the constraint for yourself

Scale beyond the available GPUs and watch what happens:

```bash
kubectl scale deployment/vllm -n inference --replicas=4
kubectl get pods -n inference -w
```

Replicas beyond the node count stay `Pending`. `kubectl describe pod` reports
`Insufficient nvidia.com/gpu`. Return to the original count:

```bash
kubectl scale deployment/vllm -n inference --replicas=2
```

## Next

[Module 9: Capstone, sharding across nodes](09-capstone-multinode.md)
