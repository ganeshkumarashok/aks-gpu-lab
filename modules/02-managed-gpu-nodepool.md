# Module 2 — The managed GPU node pool

```bash
./scripts/20-add-managed-gpu-nodepool.sh t4
```

Roughly 5–10 minutes. Slower than a CPU node pool because the driver and the
managed components install at node provisioning time.

## The one flag

```bash
az aks nodepool add \
  --resource-group "$LAB_RG" \
  --cluster-name "$LAB_CLUSTER" \
  --name gpunp \
  --node-count 1 \
  --node-vm-size Standard_NC4as_T4_v3 \
  --node-taints sku=gpu:NoSchedule \
  --enable-managed-gpu=true
```

`--enable-managed-gpu=true` sets `gpuProfile.nvidia.managementMode = Managed`,
and AKS takes ownership of four components:

| Component | What it does |
|---|---|
| NVIDIA GPU driver | kernel modules and user-space libraries |
| NVIDIA device plugin | advertises `nvidia.com/gpu` to the kubelet |
| DCGM + dcgm-exporter | GPU metrics on port `19400` |
| GPU health in NPD | `UnhealthyNvidiaDevicePlugin`, `UnhealthyNvidiaDCGMServices` |

## Three things that bite people

**1. Omitting the flag does not give you the managed stack.** The default is
*Driver only* — AKS installs the driver and nothing else, and `nvidia.com/gpu`
never appears because there is no device plugin. The three profiles are:

| Profile | Flags |
|---|---|
| Full managed stack | `--enable-managed-gpu=true` |
| Driver only (default) | `--enable-managed-gpu=false` |
| None (BYO) | `--enable-managed-gpu=false --gpu-driver None` |

**2. The profile is immutable.** `managementMode`, `migStrategy`, and `driver`
are all fixed at creation. Getting the flag wrong means deleting the node pool
and creating it again — there is no `az aks nodepool update` path back. The
script refuses to continue against an existing pool rather than pretending it
reconfigured something.

**3. AKS does not apply the GPU taint for you.** `sku=gpu:NoSchedule` is a
convention from the docs that you pass yourself. It keeps CPU workloads off
expensive nodes — but it also means *every* GPU pod needs a matching toleration.
A pod without one sits `Pending` and the events do not make the reason obvious.

## AKS picks the driver type for you

`gpuProfile.driverType` is empty by default, which means *AKS selects the driver
based on system compatibility*. You can see that decision play out by creating
both node pools in this lab and comparing them:

| Pool | SKU | Driver | CUDA | Device reported |
|---|---|---|---|---|
| `gpunp` | `Standard_NC4as_T4_v3` | 580.159.04 | 13.0 | `Tesla T4` |
| `infnp` | `Standard_NV36ads_A10_v5` | 570.211.01 | 12.8 | `NVIDIA A10-24Q` |

The `-24Q` suffix is a GRID **vGPU profile**. NC-series is the compute family and
gets the datacenter CUDA driver; NV-series is the visualization family and gets
the GRID driver. You did not ask for either — AKS chose, and the two pools ended
up on different driver branches and different CUDA versions in the same cluster.

This matters when you pin a container image: an image built against CUDA 13 will
not necessarily behave the same on the CUDA 12.8 GRID node. If you need to force
the choice, `--driver-type` accepts `GRID` or `CUDA`, and like the other
`gpuProfile` fields it is immutable after creation.

## Confirm the profile landed

```bash
az aks nodepool show -g "$LAB_RG" --cluster-name "$LAB_CLUSTER" -n gpunp --query gpuProfile
```

```json
{
  "driver": "Install",
  "driverType": "",
  "nvidia": { "managementMode": "Managed", "migStrategy": null }
}
```

If `nvidia` is `null`, the pool was created **without** the managed stack.
Delete it and recreate with the flag.

## Scaling

Managed GPU node pools do **not** support the cluster autoscaler during preview.
Scale manually:

```bash
az aks nodepool scale -g "$LAB_RG" --cluster-name "$LAB_CLUSTER" -n gpunp --node-count 2
```

This is why no module in this lab uses `--enable-cluster-autoscaler`.

## Next

[Module 3 — Verify the stack](03-verify.md)
