#!/usr/bin/env bash
# Module 6 (capstone) -- deploy a RayService that shards one model across both
# H100 nodes.
#
# Usage: 63-deploy-rayservice.sh [bringup|glm|singlenode]
#   bringup     Qwen2.5-7B, TP=4 PP=2, ~15 GB   -- proves the mechanism cheaply
#   glm         GLM-5.2-FP8, TP=8 PP=2, 703 GiB -- the real workload
#   singlenode  Qwen2.5-7B, TP=4 PP=1, 1 node   -- fallback when a second H100
#               cannot be allocated. Validates everything EXCEPT the cross-node
#               hop. A pass here is not a capstone result.
#
# Run bringup FIRST. Debugging a topology problem after an hour of downloading
# is a bad way to spend an hour.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

TARGET="${1:-bringup}"
case "$TARGET" in
  bringup)    MANIFEST="$ROOT/manifests/rayservice-bringup.yaml";   SVC=bringup;    NEED=2 ;;
  glm)        MANIFEST="$ROOT/manifests/rayservice-glm-h100.yaml";  SVC=glm;        NEED=2 ;;
  singlenode) MANIFEST="$ROOT/manifests/rayservice-singlenode.yaml"; SVC=singlenode; NEED=1 ;;
  *)          fail "Unknown target '$TARGET'. Use: bringup | glm | singlenode"; exit 2 ;;
esac

step "Preflight"
CTX=$(kubectl config current-context 2>/dev/null || echo "?")
[ "$CTX" = "$CAP_CLUSTER" ] || warn "kubectl context is '$CTX', expected '$CAP_CLUSTER'"

# Count by SKU, not by pool: capacity limits often force the two nodes into
# separate node pools (see modules/06-capstone-multinode.md).
READY=$(kubectl get nodes -l "node.kubernetes.io/instance-type=$CAP_SKU" --no-headers 2>/dev/null | grep -c " Ready ")
if [ "$READY" -lt "$NEED" ]; then
  fail "Target '$TARGET' needs $NEED Ready $CAP_SKU node(s), found $READY."
  [ "$NEED" = "2" ] && info "If a second node will not allocate, try: $0 singlenode"
  exit 1
fi
ok "$READY $CAP_SKU node(s) Ready"

kubectl get crd rayservices.ray.io >/dev/null 2>&1 || {
  fail "RayService CRD not found. Run scripts/62-install-kuberay.sh first."; exit 1; }
ok "KubeRay CRDs present"

kubectl create namespace gpu-lab --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "Deploying RayService '$SVC' ($TARGET)"
kubectl apply -f "$MANIFEST"

step "Waiting for the Ray cluster"
info "Head and workers pull rayproject/ray-llm (large), then the model downloads."
info "bringup: roughly 15-25 min. glm: substantially longer -- 703 GiB."
info "Follow along with:"
info "  kubectl get pods -n gpu-lab -w"
info "  kubectl logs -n gpu-lab -l ray.io/group=h100 -f"

# Wait for the pods to exist before waiting on their condition -- `kubectl wait`
# returns immediately with "No resources found" if the selector matches nothing
# yet, which reads as a timeout failure when it is really a race.
for _ in $(seq 1 60); do
  [ "$(kubectl get pods -n gpu-lab -l ray.io/cluster --no-headers 2>/dev/null | wc -l)" -gt 0 ] && break
  sleep 2
done

if kubectl wait --for=condition=Ready pod \
     -l "ray.io/cluster" -n gpu-lab --timeout=3600s >/dev/null 2>&1; then
  ok "Ray pods Ready"
else
  warn "Not all Ray pods reached Ready within the timeout."
  kubectl get pods -n gpu-lab -o wide
fi

step "Ray cluster topology"
kubectl get pods -n gpu-lab -o custom-columns=\
'NAME:.metadata.name,NODE:.spec.nodeName,GPUS:.spec.containers[0].resources.limits.nvidia\.com/gpu,STATUS:.status.phase' 2>/dev/null

# A multi-node test that lands both workers on one node is a single-node test.
NODES=$(kubectl get pods -n gpu-lab -l ray.io/group=h100 \
          -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null | tr ' ' '\n' | sort -u | grep -c . || echo 0)
if [ "$TARGET" = "singlenode" ]; then
  info "Workers on $NODES node(s). Single-node target -- cross-node sharding is NOT exercised."
elif [ "$NODES" -ge 2 ]; then
  ok "Workers are spread across $NODES physical nodes"
else
  fail "Workers are on $NODES node(s). This would not be a multi-node test."
fi

step "Is RDMA actually being used?"
info "NCCL announces its transport at init. Check after the model loads:"
info "  kubectl logs -n gpu-lab -l ray.io/group=h100 | grep -E 'NET/IB|NET/Socket'"
info "NET/IB   -> RDMA over InfiniBand"
info "NET/Socket -> silent TCP fallback"

step "Next"
info "Query it:  kubectl port-forward -n gpu-lab svc/${SVC}-serve-svc 8000:8000"
info "Tear down: ./scripts/90-teardown.sh --capstone-gpu-only"
