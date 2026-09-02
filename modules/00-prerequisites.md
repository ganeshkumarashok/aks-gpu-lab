# Module 0 — Prerequisites

Zero cost. Nothing is created. Run this before you spend anything on a GPU.

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

1. `az vm list-skus` returns an **empty `restrictions` array** for it in the region.
2. `az vm list-usage` shows a **non-zero limit** for its quota family.

Either one alone will mislead you. westus3 reports T4 quota of `0/300` — looks
like room for 75 nodes — while the T4 SKU itself is `NotAvailableForSubscription`
there. That is quota you cannot spend. The reverse also happens: a SKU that is
perfectly available with a family limit of `0`.

`preflight.sh` checks both and tells you which gate failed.

> **Performance note.** The preflight reads the SKU catalog through the Compute
> REST API rather than `az vm list-skus`. The CLI command filters client-side and
> takes over seven minutes per region; the REST call takes about seven seconds.

## Feature registration

The docs instruct:

```bash
az feature register --namespace Microsoft.ContainerService --name ManagedGPUExperiencePreview
```

Registration propagates asynchronously — it can sit in `Registering` for several
minutes. The preflight warns rather than fails here: an unregistered
subscription may still work. Registering is still the documented flow and is
harmless. See [accuracy notes D4](../docs/accuracy.md).

## Next

[Module 1 — Cluster](01-cluster.md)
