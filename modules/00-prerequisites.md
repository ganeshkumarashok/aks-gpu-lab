# Module 0 — Prerequisites

Time: 5 minutes. Cost: zero. This module creates no Azure resources; it only
checks your tooling, subscription access, and quota.

## Azure subscription and permissions

Before running the preflight, you need:

- An Azure subscription with quota for GPU virtual machine (VM) families in at
  least one region. This lab defaults to specific SKUs (Azure's term for a VM
  size, e.g. `Standard_NC4as_T4_v3`) in **westus2**. See
  [Adapt region and SKU to your subscription](#adapt-region-and-sku-to-your-subscription)
  below to point it at quota you have.
- The Azure CLI signed in to that subscription: `az login`, then
  `az account set --subscription <name-or-id>` if the subscription is not
  already the active one.
- Permission to register subscription-level resource provider features
  (`Microsoft.Features/register/action`) and to create resource groups and
  Azure Kubernetes Service (AKS) clusters in the subscription. The
  **Contributor** role on the subscription covers both.

## Run the preflight

```bash
./scripts/preflight.sh
```

It checks five things. Skip any one and this lab fails in a specific, real way:

| Check | Why it matters |
|---|---|
| azure-cli ≥ 2.85.0 | `--enable-managed-gpu` does not exist on older CLIs |
| aks-preview ≥ 19.0.0b29 | the flag lives in the preview extension, not core |
| `ManagedGPUExperiencePreview` | the documented feature gate |
| SKU **availability** | the SKU must be offerable to your subscription |
| SKU **quota** | the family must have room |

## The two-gate rule

The last two checks are the ones people get wrong, so they are worth stating
plainly. A GPU VM size is usable only if **both** are true:

1. `az vm list-skus` returns an **empty `restrictions` array** for it in the
   region: the array Azure uses to mark a SKU as unavailable to a given
   subscription or region even when its family shows quota.
2. `az vm list-usage` shows a **non-zero limit** for its quota family: the
   group of related VM sizes that share one quota number in a region (for
   example, the capstone's H100 SKU draws from `standardNDSFH100v5Family`,
   named in `scripts/61-capstone-h100-nodepool.sh`).

Either one alone will mislead you. westus3 reports T4 quota of `0/300`, which
looks like room for 75 nodes, while the T4 SKU itself is
`NotAvailableForSubscription` there. That is quota you cannot spend. The
reverse also happens: a SKU that is perfectly available with a family limit
of `0`.

`preflight.sh` checks both and tells you which gate failed.

> **Performance note.** The preflight reads the SKU catalog through the Compute
> REST API rather than `az vm list-skus`. The CLI command filters client-side and
> takes over seven minutes per region; the REST call takes about seven seconds.

## Adapt region and SKU to your subscription

Every region and SKU name in this lab is a default, not a requirement. They
live as environment-variable overrides in `scripts/lib.sh`:

| Variable | Default | Controls |
|---|---|---|
| `LAB_LOCATION` | `westus2` | region for modules 0–5 |
| `LAB_RG` | `aks-gpu-lab-rg` | resource group name |
| `LAB_CLUSTER` | `aks-gpu-lab` | AKS cluster name |
| `LAB_SKU_T4` | `Standard_NC4as_T4_v3` | entry GPU node pool (modules 1–4) |
| `LAB_SKU_A10` | `Standard_NV36ads_A10_v5` | driver-comparison node pool (module 2) |
| `LAB_SKU_A100` | `Standard_NC24ads_A100_v4` | inference node pool (module 5) |

`westus2` is only where the two-gate rule in the previous section happened to
clear for the subscription this lab was built against. Your subscription's
availability and quota will differ by region. To point the lab at a region or
SKU you have quota for, export the variables before running any script, for
example:

```bash
export LAB_LOCATION=eastus
```

Override `LAB_SKU_T4`, `LAB_SKU_A10`, or `LAB_SKU_A100` the same way if the
region you choose does not clear both gates for these exact SKUs. Then re-run
`./scripts/preflight.sh`: it validates whatever `LAB_LOCATION` and SKU
variables are currently set, so it tells you whether the new combination
clears both gates before you create anything. The optional capstone (module 6)
uses its own separate `CAP_LOCATION`, `CAP_SKU`, and related variables,
documented in [Module 6](09-capstone-multinode.md).

## Feature registration

The docs instruct:

```bash
az feature register --namespace Microsoft.ContainerService --name ManagedGPUExperiencePreview
```

This registers a subscription-level feature flag: the mechanism Azure uses to
gate preview functionality to subscriptions that have opted in. Registration
propagates asynchronously. It can sit in `Registering` for several minutes.
The preflight warns rather than fails here: an unregistered subscription may
still work. Registering is still the documented flow and is harmless. See
[accuracy notes D4](../docs/accuracy.md).

## Next

[Module 1: Cluster and add-ons](01-cluster.md)
