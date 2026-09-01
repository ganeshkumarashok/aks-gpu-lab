# Module 1 — Create the cluster

```bash
./scripts/10-create-cluster.sh
```

Roughly 8–12 minutes (observed ~10 on a 2-node system pool).

## What it builds

An AKS cluster with a **CPU-only system node pool** — two `Standard_D4s_v5`
nodes. No GPU yet.

That ordering is deliberate. GPU nodes are the entire cost of this lab, so they
get added in the next module and can be deleted independently. Keeping system
pods off the GPU pool means you can destroy and recreate GPU capacity without
disturbing anything else — which matters, because the managed GPU profile is
immutable and "recreate the node pool" is the standard fix for a wrong flag.

## Verify

```bash
kubectl get nodes -o wide
```

Two `Ready` nodes in the `system` pool. No `nvidia.com/gpu` anywhere yet:

```bash
kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}'
# (empty)
```

That empty output is the baseline. The next module changes it with one flag.

## Next

[Module 2 — Managed GPU node pool](02-managed-gpu-nodepool.md)
