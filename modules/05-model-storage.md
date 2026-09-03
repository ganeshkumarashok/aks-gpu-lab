# Module 5: Model storage

Serving replicas need the model weights. Where those weights live determines how
fast a replica starts, whether replicas can share, and what happens when a pod
is rescheduled.

```bash
kubectl apply -f manifests/model-storage.yaml
kubectl apply -f manifests/model-stage-job.yaml
kubectl wait --for=condition=complete job/stage-model -n inference --timeout=3600s
```

## Why not download into the pod

A container-local cache such as `emptyDir` is the obvious first approach and it
works for a single replica. It stops working at production shape:

| | `emptyDir` | Shared volume |
|---|---|---|
| Download cost | once per replica | once total |
| Pod reschedules | full re-download | remount |
| Replica start time | minutes | seconds after mount |
| Node disk pressure | one copy per pod | none |

At two replicas the difference is inconvenient. At ten it decides whether
scaling out is practical.

Baking weights into the container image is the other common approach. It gives
fast, immutable startup, at the cost of multi-gigabyte images, a rebuild per
model version, and slow node-level image pulls. It suits a fixed model; a shared
volume suits a model you expect to change.

## Which Azure storage

The AKS MLOps guidance
([Store datasets and checkpoints](https://learn.microsoft.com/azure/aks/best-practices-ml-ops))
maps workloads to storage:

| Storage | Use for |
|---|---|
| Azure Blob (NFS or BlobFuse) | large object data, model artifacts |
| Azure Files | shared POSIX access across nodes |
| Azure Disk | single-node read-write, `ReadWriteOnce` |
| Node ephemeral | caches that can be rebuilt |

Model weights are large, read-mostly, and read by every replica, so this lab
uses Blob over NFS.

The property that matters is `ReadWriteMany`. `ReadWriteOnce` binds the volume
to one node, which would force every replica onto that node and remove the
availability that running several replicas is meant to provide.

## Enable the driver

```bash
az aks update --resource-group "$LAB_RG" --name "$LAB_CLUSTER" --enable-blob-driver
```

## Stage the weights

`manifests/model-stage-job.yaml` runs the download once, as a Job rather than an
init container on the Deployment. As an init container, every replica would
start its own copy of the same download and write to the same paths.

The job is safe to re-run. `snapshot_download` resumes a partial transfer and
verifies what it already has.

It deliberately does **not** skip work by checking whether the destination
directory is non-empty. A failed download leaves files behind, so that check
reports success while shards are missing, and the failure surfaces much later
as a confusing model-load error in a serving pod.

Instead the job reads `model.safetensors.index.json`, confirms every shard named
in its `weight_map` exists and is non-empty, and exits non-zero if any is
missing:

```
incomplete download, missing or empty: ['model-00003-of-00004.safetensors']
```

A staging job that can report success without the weights being present is
worse than one that fails loudly.

## Sizing the staging job

Requests and limits do different jobs here, and setting them equal causes one of
two failures.

| | Value | Reason |
|---|---|---|
| `requests.memory` | 2Gi | governs scheduling. A large request cannot be placed on a system node already running the cluster add-ons, and the pod stays `Pending` |
| `limits.memory` | 10Gi | governs the OOM killer. Peak usage scales with download concurrency, since each worker buffers part of a multi-gigabyte shard |

Too high a request produces `FailedScheduling` with `Insufficient memory`. Too
low a limit produces an `OOMKilled` container with exit code 137, partway
through the download, with no message explaining why.

`max_workers` is the other half of that trade. More workers finish sooner and
raise peak memory; four keeps the job inside a limit a system node can satisfy.

## Verify

```bash
kubectl get pvc -n inference model-weights
kubectl logs -n inference job/stage-model | tail -3
```

The PVC reports `Bound` with `RWX` access, and the job's final line states the
shard count and total size:

```
staged 4 shard(s), 14.2 GiB, to /models/Qwen2.5-7B-Instruct
```

The PVC should be `Bound`. To confirm the files landed:

```bash
kubectl run -n inference --rm -i --restart=Never checkmodel \
  --image=mcr.microsoft.com/azurelinux/base/core:3.0 \
  --overrides='{"spec":{"containers":[{"name":"c","image":"mcr.microsoft.com/azurelinux/base/core:3.0","command":["sh","-c","du -sh /models/* && ls /models/*/ | head"],"volumeMounts":[{"name":"m","mountPath":"/models"}]}],"volumes":[{"name":"m","persistentVolumeClaim":{"claimName":"model-weights"}}]}}'
```

Expect a directory of roughly the checkpoint size containing `config.json` and
one or more `.safetensors` files.

## Cost

The volume is provisioned `Premium_LRS` and billed for its size whether or not
it is mounted. `./scripts/90-teardown.sh` deletes it with the resource group;
the StorageClass uses `reclaimPolicy: Delete`, so removing the PVC also removes
the underlying container.

## Next

[Module 6: The inference service](06-inference-service.md)
