# Module 6 — Capstone: multi-node sharded serving (optional)

> **Read this section first.** This module deliberately leaves the ground the
> rest of the lab stands on. Modules 0–5 are built entirely on published AKS
> documentation. This one is not, and it is labelled that way on purpose.

## What is and is not documented

| Layer | AKS documentation |
|---|---|
| KubeRay, `RayService`, Kueue | **Documented** — `ray-overview.md`, `deploy-ray-infrastructure.md`, `ray-online-serving.md` |
| Distributed *training* on GPUs | **Documented** — `ray-train-llm.md` (4× A100) |
| Multi-node **sharded serving** | **Not documented** — the Ray series tops out at 1× GPU for `RayService` |
| GPUDirect RDMA, `nvidia-peermem` | **Not documented** — zero references in the AKS docs |
| InfiniBand for NVIDIA | **Not documented** — `AKSInfinibandSupport` appears only in `use-amd-gpus.md`, for AMD MI300X |

So the orchestration layer is supported and the distribution and RDMA layers are
not. That shapes how this module is built.

## The design decision: RDMA as a measurement, not a prerequisite

Ray plus vLLM will shard a model across nodes over ordinary pod networking. It
is slower than RDMA, but it *works*, and it works on documented ground.

So this module does it in that order:

1. Get sharded serving running over standard networking. Measure it.
2. Enable InfiniBand. Measure it again.
3. Report the delta.

That turns the undocumented part into an experiment with a number attached,
rather than a configuration step the lab has to assert without a citation. If
step 2 does not work, step 1 is still a complete, honest module.

## Infrastructure

This capstone cannot share a cluster with modules 0–5. GPU quota forces a
different region:

| | Modules 0–5 | Capstone |
|---|---|---|
| Region | westus2 | **swedencentral** |
| SKU | T4 / A10 | `Standard_ND96isrf_H100_v5` |
| Nodes | 1 | **2** (entire family quota) |
| GPUs | 1 | 16× H100 |

### The SKU name is not the one in the docs

`best-practices-storage-nvme.md` refers to `Standard_ND96isr_H100_v5` — without
the `f`. That SKU is `NotAvailableForSubscription` in every region checked. The
deployable variant is `Standard_ND96isrf_H100_v5`, which appears in **no**
AKS documentation. Verify against your own subscription before planning around
either name:

```bash
az rest --method get --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Compute/skus?api-version=2021-07-01&\$filter=location%20eq%20'swedencentral'" \
  | jq -r '.value[] | select(.name|test("H100")) | "\(.name) \(.family) \(.restrictions|length)"'
```

The non-RDMA variant `Standard_ND96isf_H100_v5` shares the **same quota
family**, so spending quota there consumes your RDMA budget.

## Cost and blast radius

This is the most expensive thing in the lab by a wide margin, and two nodes is
the *entire* family quota — there is no room to run a second attempt in parallel
while a first one is up. Treat a capstone run as a deliberate, budgeted session:
plan the run, execute it, capture the numbers, tear it down.

```bash
./scripts/90-teardown.sh    # do not leave this running
```

## Status

Not yet built or validated. Modules 0–5 are the complete, verified lab; this
module is scoped and specified but its scripts are not written, and nothing here
should be treated as tested until it is.
