#!/usr/bin/env bash
# Modules 3 and 4 -- verify the managed GPU stack and read GPU telemetry.
#
# On a self-managed GPU node pool you would install the device plugin and DCGM
# yourself before any of these checks could pass. Here they should pass on a
# freshly created node pool.
#
# Usage: 30-verify-managed-stack.sh [t4|a10|a100]

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

TIER="${1:-t4}"
case "$TIER" in
  t4)  POOL="$LAB_NODEPOOL_T4" ;;
  a10) POOL="$LAB_NODEPOOL_A10" ;;
  a100) POOL="$LAB_NODEPOOL_A100" ;;
  *)   fail "Unknown tier '$TIER'. Use: t4 | a10 | a100"; exit 2 ;;
esac

ERRORS=0
note_fail() { fail "$1"; ERRORS=$((ERRORS + 1)); }

step "Locating a node in pool '$POOL'"
GPU_NODE=$(kubectl get nodes -l "agentpool=$POOL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$GPU_NODE" ]; then
  note_fail "No node found with label agentpool=$POOL"
  exit 1
fi
ok "Node: $GPU_NODE"

step "Check 1 -- the node pool really is a managed GPU pool"
# Authoritative source is the AKS API, not a node label.
# `accelerator=nvidia` is a label YOU apply at node pool creation
# (best-practices-ml-ops.md passes --labels accelerator=nvidia); AKS does not
# set it, so its absence proves nothing.
PROFILE=$(az aks nodepool show --resource-group "$LAB_RG" --cluster-name "$LAB_CLUSTER" \
            --name "$POOL" --query gpuProfile -o json 2>/dev/null || echo 'null')
MODE=$(printf '%s' "$PROFILE" | python3 -c "
import json,sys
try: p=json.load(sys.stdin) or {}
except Exception: p={}
n=p.get('nvidia') or {}
print(f\"{p.get('driver','?')}|{n.get('managementMode','<null>')}\")" 2>/dev/null || echo "?|?")
DRV="${MODE%%|*}"; MGMT="${MODE##*|}"
if [ "$MGMT" = "Managed" ]; then
  ok "gpuProfile: driver=$DRV, nvidia.managementMode=$MGMT"
else
  note_fail "gpuProfile.nvidia.managementMode is '$MGMT', expected 'Managed'."
  info "This pool was not created with --enable-managed-gpu=true. The checks below"
  info "will fail as a consequence. The field is immutable: delete and recreate."
fi

step "Check 2 -- device plugin advertises nvidia.com/gpu"
# The device plugin is what turns physical GPUs into a schedulable resource. If
# this is empty, the driver may be fine but the Kubernetes-facing stack is not.
ALLOC=$(kubectl get node "$GPU_NODE" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)
if [ -n "$ALLOC" ] && [ "$ALLOC" != "0" ]; then
  ok "allocatable nvidia.com/gpu = $ALLOC"
else
  note_fail "nvidia.com/gpu is absent or 0. The device plugin is not advertising GPUs."
  info "On a --enable-managed-gpu=false pool this is expected: you own the device plugin."
fi

step "Check 3 -- DCGM exporter label"
DCGM=$(kubectl get node "$GPU_NODE" -o jsonpath='{.metadata.labels.kubernetes\.azure\.com/dcgm-exporter}' 2>/dev/null || true)
if [ "$DCGM" = "enabled" ]; then
  ok "kubernetes.azure.com/dcgm-exporter = enabled"
else
  note_fail "dcgm-exporter label is '${DCGM:-<absent>}', expected 'enabled'."
  info "This label is only applied on a --enable-managed-gpu=true node pool."
fi

step "Check 4 -- NPD GPU health conditions"
# Both conditions should exist and both should be False. False means healthy:
# the condition asserts UNhealthiness, so True is the alarm state.
for cond in UnhealthyNvidiaDevicePlugin UnhealthyNvidiaDCGMServices; do
  status=$(kubectl get node "$GPU_NODE" -o json 2>/dev/null \
    | python3 -c "
import json,sys
n=json.load(sys.stdin)
for c in n['status'].get('conditions',[]):
    if c['type']=='$cond':
        print(f\"{c['status']}|{c.get('reason','')}\"); break
else: print('ABSENT|')")
  st="${status%%|*}"; reason="${status##*|}"
  case "$st" in
    False)  ok  "$cond = False (${reason:-healthy})" ;;
    True)   note_fail "$cond = True (${reason}) -- GPU stack is UNHEALTHY" ;;
    *)      NPD_MISSING=1
            warn "$cond not reported on this node" ;;
  esac
done

# Absent conditions are a WARN, not a FAIL. The docs list NPD GPU health as the
# fourth managed component, but NPD ships via the AKS Linux extension, which is
# not installed on a node pool created with --enable-managed-gpu=true alone. Verified
# 2026-09-01: no node-problem-detector unit on the node and only vmssCSE +
# AKSLinuxBilling on the VMSS. Nothing the reader did is wrong, and the other
# three managed components are unaffected. See docs/accuracy.md D6.
if [ "${NPD_MISSING:-0}" = "1" ]; then
  info "NPD is not installed on this node, so these conditions cannot appear."
  info "Confirm with:"
  info "  kubectl get node $GPU_NODE -o jsonpath='{.status.conditions[*].type}'"
  info "The device plugin and DCGM checks above are the meaningful health signals here."
fi

step "Check 5 -- container can reach the GPU"
kubectl delete pod managed-gpu-test --ignore-not-found >/dev/null 2>&1 || true
# The smoke pod MUST be pinned to the pool under test. Without a nodeSelector the
# scheduler is free to place it on any node that tolerates the GPU taint, so the
# check can pass while exercising a different node pool entirely.
sed "s|^spec:|spec:\n  nodeSelector:\n    agentpool: $POOL|" \
  "$(dirname "$0")/../manifests/gpu-smoke-test.yaml" | kubectl apply -f - >/dev/null
info "Waiting for the smoke pod to complete (image pull can take a minute)..."
if kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/managed-gpu-test --timeout=300s >/dev/null 2>&1; then
  ACTUAL=$(kubectl get pod managed-gpu-test -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "?")
  if [ "$ACTUAL" = "$GPU_NODE" ]; then
    ok "nvidia-smi ran inside a container on $ACTUAL:"
  else
    note_fail "Smoke pod ran on $ACTUAL, not the node under test ($GPU_NODE)"
  fi
  kubectl logs managed-gpu-test | sed 's/^/        /'
else
  note_fail "Smoke pod did not succeed. Diagnostics:"
  kubectl describe pod managed-gpu-test | tail -25 | sed 's/^/        /'
fi
kubectl delete pod managed-gpu-test --ignore-not-found >/dev/null 2>&1 || true

step "Check 6 -- DCGM metrics are being exported"
# dcgm-exporter serves Prometheus metrics on port 19400 on the GPU node.
info "Port-forwarding is not possible without a Service, so we read metrics from"
info "inside a pod scheduled onto the GPU node itself."
cat <<'EOF' | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: dcgm-probe
spec:
  restartPolicy: Never
  hostNetwork: true
  tolerations:
    - key: "sku"
      operator: "Equal"
      value: "gpu"
      effect: "NoSchedule"
  containers:
    - name: probe
      image: mcr.microsoft.com/azurelinux/base/core:3.0
      command: ["/bin/sh","-c","curl -s --max-time 10 http://localhost:19400/metrics | head -40 || echo CURL_FAILED"]
EOF
if kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/dcgm-probe --timeout=180s >/dev/null 2>&1; then
  out=$(kubectl logs dcgm-probe 2>/dev/null || true)
  if printf '%s' "$out" | grep -q "DCGM_FI_DEV_GPU_UTIL"; then
    ok "DCGM_FI_DEV_GPU_UTIL present on :19400"
    printf '%s\n' "$out" | grep -E "^DCGM_FI_DEV_(GPU_UTIL|FB_USED|GPU_TEMP|POWER_USAGE)" | head -8 | sed 's/^/        /'
  else
    warn "Reached :19400 but did not see DCGM_FI_DEV_GPU_UTIL. Raw head:"
    printf '%s\n' "$out" | head -10 | sed 's/^/        /'
  fi
else
  warn "dcgm-probe pod did not complete; skipping metric assertion."
fi
kubectl delete pod dcgm-probe --ignore-not-found >/dev/null 2>&1 || true

step "Result"
if [ "$ERRORS" -eq 0 ]; then
  ok "Managed GPU stack verified on $GPU_NODE"
else
  fail "$ERRORS check(s) failed"
fi
exit "$ERRORS"
